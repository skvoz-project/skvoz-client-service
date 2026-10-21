# frozen_string_literal: true
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'socket'

module ClientNative
  ROOT = File.expand_path('../..', __dir__)

  def wait_until(seconds = 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return if yield
      raise IOError, 'Integration deadline exceeded' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  end

  def capture(environment, *arguments)
    Open3.popen3(environment, *arguments) do |input, output, error, process|
      input.close
      readers = [output, error].map { |io| Thread.new { io.read(65_537).to_s } }
      begin
        result = Timeout.timeout(20) do
          values = readers.map(&:value)
          raise IOError, 'Command output exceeds limit' if values.any? { |value| value.bytesize > 65_536 }
          [*values, process.value]
        end
        raise IOError, 'Command failed' unless result.last.success? && result.first.bytesize <= 65_536
        result.first
      ensure
        Process.kill('KILL', process.pid) rescue Errno::ESRCH if process.alive?
        process.join(5)
        readers.each { |thread| thread.kill if thread.alive? }
      end
    end
  end

  def stop_process(pid, seconds = 12)
    return unless pid
    Process.kill('TERM', pid) rescue Errno::ESRCH
    Timeout.timeout(seconds) { Process.waitpid(pid) }
  rescue Timeout::Error
    Process.kill('KILL', -pid) rescue Errno::ESRCH
    Timeout.timeout(5) { Process.waitpid(pid) }
  rescue Errno::ECHILD
    nil
  end

  class Target
    attr_reader :port
    def initialize(port, &handler)
      @listener = TCPServer.new('127.0.0.1', port)
      @port = @listener.local_address.ip_port
      @worker = Thread.new do
        loop do
          @socket = @listener.accept
          handler.call(@socket)
          @socket.close
        end
      rescue IOError, SystemCallError
        nil
      end
    end
    def close
      @socket&.close
      @listener.close
      @worker.join(1)
      @worker.kill if @worker.alive?
    end
  end

  class Fixture
    attr_reader :metadata

    def initialize
      profile = ENV.fetch('SKVOZ_SERVER_TEST_PROFILE')
      @metadata = File.open(profile, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise IOError, 'Integration profile must be a private owned regular file' unless stat.file? && stat.uid == Process.uid && stat.mode & 0o777 == 0o600 && stat.size.between?(1, 65_536)
        JSON.parse(file.read(65_537), max_nesting: 8, allow_duplicate_key: false)
      end
      raise IOError, 'Unexpected integration profile fields' unless @metadata.keys.sort == %w[admin_socket bundle target_ports]
      ports = @metadata.fetch('target_ports')
      raise IOError, 'Integration requires three distinct target ports' unless ports.is_a?(Array) && ports.size == 3 && ports.uniq.size == 3 && ports.all? { |port| port.is_a?(Integer) && port.between?(1024, 65_535) }
      socket = File.lstat(@metadata.fetch('admin_socket'))
      raise IOError, 'Integration admin socket must be private and owned' unless socket.socket? && socket.uid == Process.uid && socket.mode & 0o777 == 0o600
    end

    def remove
      request = { operation: 'remove', login: @metadata.fetch('bundle').fetch('username') }
      Timeout.timeout(20) do
        UNIXSocket.open(@metadata.fetch('admin_socket')) do |socket|
          raise IOError, 'Unexpected Server admin peer' unless socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).unpack('iii')[1] == Process.uid
          socket.write(JSON.generate(request) + "\n")
          bytes = socket.gets("\n", 65_537)
          raise IOError, 'Invalid Server admin response' unless bytes && bytes.bytesize <= 65_536 && bytes.end_with?("\n")
          response = JSON.parse(bytes, max_nesting: 8, allow_duplicate_key: false)
          raise IOError, 'Server admin request failed' unless response['ok'] == true && response.key?('result')
          response.fetch('result')
        end
      end
    end
  end
end
