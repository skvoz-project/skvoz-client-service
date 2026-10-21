# frozen_string_literal: true
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'timeout'
require 'tmpdir'
require 'uri'

module Skvoz
  # Download pinned archives and extract only the product files used by this client.
  class NativeArtifact
    ROOT = 'https://github.com/skvoz-project/skvoz-network/releases/download/'
    ASSET = 'skvoz-network-0.7.0-x86_64-unknown-linux-gnu.tar.gz'
    TAG = /\Anetwork-v0\.7\.0-[0-9a-f]{40}\z/
    LIMIT = 256 * 1024 * 1024
    FILES = %w[
      bin/skvoz-network-runtime
      bin/skvoz-network-helper
      lib/libskvoz_core.so
      resources/systemd/skvoz-network-helper@.socket
      resources/systemd/skvoz-network-helper@.service
      resources/systemd/skvoz-network-helper.conf
      resources/polkit/org.skvoz.network.policy
      licenses/Network-MIT.txt
      licenses/Core-MIT.txt
      licenses/async-nats-Apache-2.0.txt
      source-inputs.sha256
      manifest.json
    ].freeze

    def initialize(lock_path)
      @path = File.expand_path(lock_path)
      raise ArgumentError, 'Artifact lock exceeds limit' if File.size(@path) > 65_536
      @lock = JSON.parse(File.binread(@path), max_nesting: 12, allow_duplicate_key: false)
      artifact = @lock.fetch('artifact')
      unless artifact.keys.sort == %w[sha256 url] && artifact['sha256'].is_a?(String) && artifact['sha256'].match?(/\A[0-9a-f]{64}\z/) &&
          artifact['url'].is_a?(String) && artifact['url'].bytesize.between?(1, 4096)
        raise ArgumentError, 'Invalid artifact locator'
      end
    end

    def self.install(lock_path, destination, archive: nil)
      new(lock_path).install(destination, archive:)
    end

    def fetch(destination, archive: nil)
      raise ArgumentError, 'Artifact archive destination already exists' if File.exist?(destination) || File.symlink?(destination)
      created = true
      transfer(archive || @lock.dig('artifact', 'url'), destination, local: !archive.nil?)
      raise ArgumentError, 'Artifact archive digest mismatch' unless Digest::SHA256.file(destination).hexdigest == @lock.dig('artifact', 'sha256')
      destination
    rescue StandardError
      FileUtils.rm_f(destination) if created
      raise
    end

    def install(destination, archive: nil)
      destination = File.expand_path(destination)
      raise ArgumentError, 'Artifact destination already exists' if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      Dir.mktmpdir('.skvoz-native-', File.dirname(destination)) do |temporary|
        authenticated = File.join(temporary, 'network.tar.gz')
        fetch(authenticated, archive:)
        staged = File.join(temporary, 'native')
        Dir.mkdir(staged)
        unless system({ 'TAR_OPTIONS' => nil }, 'timeout', '--signal=KILL', '60', 'tar', '-xzf', authenticated, '-C', staged,
            '--no-same-owner', '--no-same-permissions', '--keep-old-files', '--no-recursion', '--', *FILES)
          raise IOError, 'Native archive extraction failed'
        end
        FILES.each do |name|
          path = File.join(staged, name)
          raise ArgumentError, 'Native payload must be a regular file' unless File.lstat(path).file?
          File.chmod(name.start_with?('bin/') ? 0o755 : 0o644, path)
          parent = File.dirname(path)
          while parent.start_with?(staged)
            raise ArgumentError, 'Native parent must be a directory' unless File.lstat(parent).directory?
            File.chmod(0o755, parent)
            break if parent == staged
            parent = File.dirname(parent)
          end
        end
        unless system('mv', '-T', '--no-clobber', '--', staged, destination) && !File.exist?(staged)
          raise ArgumentError, 'Native destination appeared during extraction'
        end
      end
      destination
    end

    def pin_release(tag)
      raise ArgumentError, 'Invalid exact Network release tag' unless tag.is_a?(String) && tag.match?(TAG)
      Dir.mktmpdir('.skvoz-pin-', File.dirname(@path)) do |temporary|
        sums = File.join(temporary, 'SHA256SUMS')
        transfer("#{ROOT}#{tag}/SHA256SUMS", sums, limit: 65_536)
        entries = {}
        File.foreach(sums) do |line|
          match = /\A([0-9a-f]{64})  ([A-Za-z0-9_.-]+)\n?\z/.match(line)
          raise ArgumentError, 'Invalid release checksum inventory' unless match && !entries.key?(match[2])
          entries[match[2]] = match[1]
        end
        candidate = @lock.merge('artifact' => { 'url' => "#{ROOT}#{tag}/#{ASSET}", 'sha256' => entries.fetch(ASSET) })
        path = File.join(temporary, 'lock.json')
        File.write(path, JSON.pretty_generate(candidate) + "\n", perm: File.stat(@path).mode & 0o777)
        self.class.new(path).install(File.join(temporary, 'verified'))
        File.rename(path, @path)
        candidate
      end
    end

    private

    def transfer(locator, destination, local: false, limit: LIMIT)
      uri = local ? nil : URI.parse(locator)
      path = locator if local
      if uri&.scheme == 'file' && (uri.host.nil? || uri.host.empty?) && !uri.query && !uri.fragment
        path = File.expand_path(URI::DEFAULT_PARSER.unescape(uri.path || uri.opaque), File.dirname(@path))
      end
      size = 0
      File.open(destination, 'wb', 0o600) do |output|
        consume = lambda do |bytes|
          size += bytes.bytesize
          raise ArgumentError, 'Artifact download exceeds limit' if size > limit
          output.write(bytes)
        end
        if path
          File.open(path, 'rb') do |input|
            while (bytes = input.read(65_536))
              consume.call(bytes)
            end
          end
        else
          Timeout.timeout(180) { https(uri, consume) }
        end
      end
    end

    def https(uri, consume, redirects = 0)
      raise ArgumentError, 'Artifact URL must use HTTPS or a local file' unless uri.scheme == 'https' && uri.host && !uri.userinfo && !uri.fragment
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15, write_timeout: 15, max_retries: 0) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          if response.is_a?(Net::HTTPRedirection)
            raise ArgumentError, 'Artifact redirect budget exceeded' if redirects == 3
            https(URI.join(uri.to_s, response.fetch('location')), consume, redirects + 1)
          else
            raise IOError, 'Artifact download failed' unless response.is_a?(Net::HTTPSuccess)
            response.read_body { |bytes| consume.call(bytes) }
          end
        end
      end
    end
  end
end
