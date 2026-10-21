# frozen_string_literal: true
require 'bundler/setup'
require 'rspec'
require_relative '../lib/skvoz/client/native_artifact'

RSpec.describe Skvoz::NativeArtifact do
  around do |example|
    Dir.mktmpdir('skvoz-native-consumer-spec-') do |directory|
      @directory = directory
      @archive = File.join(directory, 'network.tar.gz')
      @lock = File.join(directory, 'lock.json')
      @destination = File.join(directory, 'installed')
      archive
      pin
      example.run
    end
  end

  def archive(files: described_class::FILES)
    require 'rubygems/package'
    require 'zlib'
    Zlib::GzipWriter.open(@archive) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        files.each { |path| tar.add_file_simple(path, 0o644, path.bytesize) { |entry| entry.write(path) } }
        tar.add_file_simple('bin/unneeded-tool', 0o755, 6) { |entry| entry.write('unused') }
      end
    end
  end

  def pin
    @value = { 'schema' => 1, 'artifact' => { 'url' => 'file:network.tar.gz', 'sha256' => Digest::SHA256.file(@archive).hexdigest } }
    File.write(@lock, JSON.generate(@value))
  end

  def transport
    tag = 'network-v0.7.0-' + 'a' * 40
    data = { "#{described_class::ROOT}#{tag}/SHA256SUMS" => "#{Digest::SHA256.file(@archive).hexdigest}  #{described_class::ASSET}\n",
      "#{described_class::ROOT}#{tag}/#{described_class::ASSET}" => File.binread(@archive) }
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).with('github.com', 443, use_ssl: true, open_timeout: 10, read_timeout: 15, write_timeout: 15, max_retries: 0).and_yield(http)
    allow(http).to receive(:request) do |request, &block|
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(response).to receive(:read_body).and_yield(data.fetch(request.uri.to_s))
      block.call(response)
    end
    tag
  end

  it 'extracts required product files from pinned bytes without a supplier executable' do
    previous = File.umask(0o077)
    begin
      described_class.new(@lock).install(@destination)
    ensure
      File.umask(previous)
    end
    described_class::FILES.each do |name|
      path = File.join(@destination, name)
      expect(File.binread(path)).to eq(name)
      expect(File.stat(path).mode & 0o777).to eq(name.start_with?('bin/') ? 0o755 : 0o644)
    end
    expect(File.exist?(File.join(@destination, 'bin/unneeded-tool'))).to be(false)
    expect(File.stat(File.join(@destination, 'lib')).mode & 0o777).to eq(0o755)
    expect(Dir.glob(File.join(@directory, '.skvoz-native-*'))).to be_empty
  end

  it 'rejects corrupt bytes and preserves existing destinations and downloads' do
    File.binwrite(@archive, 'corrupt')
    expect { described_class.new(@lock).install(@destination) }.to raise_error(ArgumentError, /digest mismatch/)
    expect(File.exist?(@destination)).to be(false)
    File.write(@destination, 'owned')
    expect { described_class.new(@lock).install(@destination) }.to raise_error(ArgumentError, /already exists/)
    expect(File.read(@destination)).to eq('owned')
    expect { described_class.new(@lock).fetch(@archive) }.to raise_error(ArgumentError, /already exists/)
    expect(File.read(@archive)).to eq('corrupt')
  end

  it 'does not publish partial output for missing or duplicate required files' do
    [described_class::FILES - ['lib/libskvoz_core.so'], described_class::FILES + ['lib/libskvoz_core.so']].each do |files|
      archive(files:); pin
      expect { described_class.new(@lock).install(@destination) }.to raise_error(IOError, /extraction failed/)
      expect(File.exist?(@destination)).to be(false)
      expect(Dir.glob(File.join(@directory, '.skvoz-native-*'))).to be_empty
    end
  end

  it 'refreshes only an exact release after its archive extracts successfully' do
    tag = transport
    described_class.new(@lock).pin_release(tag)
    expect(JSON.parse(File.read(@lock)).dig('artifact', 'url')).to eq("#{described_class::ROOT}#{tag}/#{described_class::ASSET}")
    expect(Dir.glob(File.join(@directory, '.skvoz-pin-*'))).to be_empty
  end

  it 'keeps the pin unchanged on invalid tags, transport failure or incomplete archives' do
    old = File.binread(@lock)
    expect { described_class.new(@lock).pin_release('latest') }.to raise_error(ArgumentError, /exact/)
    allow(Net::HTTP).to receive(:start).and_raise(IOError, 'unavailable')
    expect { described_class.new(@lock).pin_release('network-v0.7.0-' + 'a' * 40) }.to raise_error(IOError, /unavailable/)
    archive(files: described_class::FILES - ['lib/libskvoz_core.so']); pin; old = File.binread(@lock)
    tag = transport
    expect { described_class.new(@lock).pin_release(tag) }.to raise_error(IOError, /extraction failed/)
    expect(File.binread(@lock)).to eq(old)
    expect(Dir.glob(File.join(@directory, '.skvoz-pin-*'))).to be_empty
  end
end
