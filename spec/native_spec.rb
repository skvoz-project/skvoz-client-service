# frozen_string_literal: true
require_relative '../lib/skvoz/client'
require_relative 'support/native'

RSpec.describe 'Client Service with a ready Server product', skip: ENV['SKVOZ_INTEGRATION'] != '1' do
  include ClientNative

  def connect_proxy(port, target)
    socket = TCPSocket.new('127.0.0.1', port)
    socket.write("CONNECT 127.0.0.1:#{target} HTTP/1.1\r\nHost: 127.0.0.1:#{target}\r\n\r\n")
    header = Timeout.timeout(10) { socket.gets("\r\n\r\n", 8193) }
    raise IOError, 'CONNECT failed' unless header && header.start_with?('HTTP/1.1 200 ') && header.end_with?("\r\n\r\n")
    socket
  rescue StandardError
    socket&.close
    raise
  end

  def start_client(environment, log)
    Process.spawn(environment, RbConfig.ruby, File.join(ClientNative::ROOT, 'bin/skvoz-client'), 'serve',
      in: File::NULL, out: log, err: log, pgroup: true)
  end

  it 'verifies TLS, streams opaque bytes, preserves half-close and identity, and retires revoked traffic' do
    raise IOError, 'Integration requires UID10001' unless Process.euid == 10001
    Timeout.timeout(180) do
      Dir.mktmpdir('skvoz-client-native-') do |directory|
        fixture = ClientNative::Fixture.new
        echo_port, half_port, http_port = fixture.metadata.fetch('target_ports')
        echo = ClientNative::Target.new(echo_port) do |socket|
          loop { socket.write(socket.readpartial(4096)) }
        rescue EOFError
          nil
        end
        half = ClientNative::Target.new(half_port) { |socket| socket.write(socket.read.reverse) }
        http = ClientNative::Target.new(http_port) do |socket|
          head = socket.gets("\r\n\r\n", 65_537)
          raise IOError, 'Unexpected HTTP target' unless head&.start_with?('POST /base/upload?q=1 HTTP/1.1')
          length = Integer(head[/content-length: (\d+)/i, 1])
          body = socket.read(length)
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" + body)
        end
        bundle = fixture.metadata.fetch('bundle')
        ca = File.join(directory, 'ca.pem')
        File.write(ca, bundle.fetch('ca_pem'), perm: 0o600)
        ports = 3.times.map { TCPServer.new('127.0.0.1', 0) }
        proxy_port, forward_port, gateway_port = ports.map { |socket| socket.local_address.ip_port }
        ports.each(&:close)
        profile = { 'server' => "#{bundle.fetch('address')}:#{bundle.fetch('port')}",
          'username' => bundle.fetch('username'), 'password' => bundle.fetch('password'), 'ca_file' => ca,
          'proxy' => { 'http' => "127.0.0.1:#{proxy_port}" },
          'tcp' => { 'half' => { 'listen' => "127.0.0.1:#{forward_port}", 'target' => "127.0.0.1:#{half.port}" } },
          'http' => { 'upload' => { 'listen' => "127.0.0.1:#{gateway_port}", 'upstream' => "http://127.0.0.1:#{http.port}/base/" } } }
        [profile.merge('server' => "wrong.example:#{bundle.fetch('port')}"), profile.reject { |key, _| key == 'ca_file' }].each do |invalid|
          Async do
            enrollment = Skvoz::Client::Enrollment.new(Skvoz::Client::Config.new(invalid.to_yaml), '127.0.0.1')
            expect { enrollment.call('f' * 32) }.to raise_error(Skvoz::Client::Terminal, 'certificate_failed')
          end.wait
        end
        run = File.join(directory, 'run'); Dir.mkdir(run, 0o700)
        state = File.join(directory, 'state')
        environment = { 'SKVOZ_CLIENT_CONFIG' => profile.to_yaml, 'SKVOZ_CLIENT_RUN' => run,
          'SKVOZ_CLIENT_STATE' => state, 'SKVOZ_RUNTIME_BINARY' => ENV.fetch('SKVOZ_TEST_RUNTIME'),
          'SKVOZ_CLIENT_ENDPOINT' => '127.0.0.1' }
        log = File.open(File.join(directory, 'client.log'), 'wb', 0o600)
        client = start_client(environment, log)
        wait_until(60) { Skvoz::Client::Service.health(run)['healthy'] }
        expect(JSON.parse(capture(environment, RbConfig.ruby, File.join(ClientNative::ROOT, 'bin/skvoz-client'), 'health'))).to include('healthy' => true)
        device = File.binread(File.join(state, 'device.json'))
        payload = "\x00\xffopaque\r\n".b
        socket = Timeout.timeout(10) { TCPSocket.new('127.0.0.1', forward_port) }
        socket.write(payload); socket.close_write
        expect(Timeout.timeout(15) { socket.read }).to eq(payload.reverse)
        socket.close
        socket = TCPSocket.new('127.0.0.1', gateway_port)
        socket.write("POST /upload?q=1 HTTP/1.1\r\nHost: gateway\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n" + payload)
        response = Timeout.timeout(15) { socket.read }
        expect(response.split("\r\n\r\n", 2)).to match([a_string_including('200 OK'), payload])
        socket.close
        stop_process(client); client = nil
        expect(Skvoz::Client::Service.health(run)['healthy']).to be false
        client = start_client(environment, log)
        wait_until(60) { Skvoz::Client::Service.health(run)['healthy'] }
        expect(File.binread(File.join(state, 'device.json'))).to eq(device)
        socket = connect_proxy(proxy_port, echo.port)
        socket.write(payload)
        expect(Timeout.timeout(10) { socket.read(payload.bytesize) }).to eq(payload)
        expect(fixture.remove).to include('removed' => bundle.fetch('username'))
        retired = begin
          Timeout.timeout(15) { socket.read(1) }
        rescue Errno::ECONNRESET
          nil
        end
        expect(retired).to be_nil
        wait_until(15) { !Skvoz::Client::Service.health(run)['healthy'] }
      ensure
        socket&.close unless socket&.closed?
        stop_process(client)
        [echo, half, http].compact.each(&:close)
        log&.close
        ports&.each { |port| port.close unless port.closed? }
      end
    end
  end
end

RSpec.describe ClientNative::Fixture do
  around do |example|
    Dir.mktmpdir('skvoz-admin-profile-spec-') do |directory|
      @server = UNIXServer.new(File.join(directory, 'admin.sock'))
      File.chmod(0o600, @server.path)
      @profile = File.join(directory, 'profile.json')
      @metadata = { 'bundle' => { 'username' => 'example' }, 'admin_socket' => @server.path, 'target_ports' => [12_001, 12_002, 12_003] }
      File.write(@profile, JSON.generate(@metadata), perm: 0o600)
      previous = ENV['SKVOZ_SERVER_TEST_PROFILE']
      ENV['SKVOZ_SERVER_TEST_PROFILE'] = @profile
      example.run
    ensure
      @server&.close
      @socket&.close unless @socket&.closed?
      @worker&.join(1)
      @worker&.kill if @worker&.alive?
      ENV['SKVOZ_SERVER_TEST_PROFILE'] = previous
    end
  end

  def serve(response)
    @worker = Thread.new do
      @socket = @server.accept
      request = JSON.parse(@socket.gets("\n", 65_537))
      @socket.write(response)
      request
    ensure
      @socket&.close unless @socket&.closed?
    end
  end

  it 'uses only the public bounded admin request and returns its result' do
    serve(JSON.generate(ok: true, result: { removed: 'example' }) + "\n")
    fixture = described_class.new
    expect(fixture.remove).to eq('removed' => 'example')
    expect(@worker.value).to eq('operation' => 'remove', 'login' => 'example')
  end

  it 'rejects nonprivate profiles, broad or duplicate target ports, and nonprivate sockets' do
    File.chmod(0o644, @profile)
    expect { described_class.new }.to raise_error(IOError, /private owned/)
    File.chmod(0o600, @profile)
    [[12_001, 12_001, 12_003], [1, 12_002, 12_003], [12_001, 12_002]].each do |ports|
      File.write(@profile, JSON.generate(@metadata.merge('target_ports' => ports)))
      expect { described_class.new }.to raise_error(IOError, /three distinct target ports/)
    end
    File.write(@profile, JSON.generate(@metadata))
    File.chmod(0o666, @server.path)
    expect { described_class.new }.to raise_error(IOError, /private and owned/)
  end

  it 'rejects admin failures and oversized responses without returning untrusted results' do
    serve(JSON.generate(ok: false, error: 'denied') + "\n")
    expect { described_class.new.remove }.to raise_error(IOError, /request failed/)
    @worker.join
    serve('x' * 65_537 + "\n")
    expect { described_class.new.remove }.to raise_error(IOError, /Invalid Server admin response/)
  end
end
