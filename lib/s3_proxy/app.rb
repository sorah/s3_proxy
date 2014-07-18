require 'aws-sdk-core'
require 'stringio'
require 'net/http'
require 'net/https'
require 'uri'
require 'aws4_signer'

require 'thread'
#
#class Net::BufferedIO
#  def initialize(io)
#      @io = io
#      @read_timeout = 60
#      @continue_timeout = nil
#      @debug_output = STDOUT
#      @rbuf = ''
#  end
#
#  def debug_output=(o)
#    o
#  end
#end

module S3Proxy
  # https://github.com/aws/aws-sdk-core-ruby/pull/79
  module AwsInstanceProfileThreadSafe
    def refresh!
      (@refresh_mutex ||= Mutex.new).synchronize do
        super
      end
    end
  end
  ::Aws::InstanceProfileCredentials.prepend AwsInstanceProfileThreadSafe

  class App
    def initialize(options={})
      @options = options
    end

    def call(env)
      return Errors.method_not_allowed unless %w(GET HEAD).include?(env['REQUEST_METHOD'])
      return Errors.not_found if env['PATH_INFO'].empty?

      # When used as a forward proxy
      if env['HTTP_HOST'] =~ /(.+)\.s3\.amazonaws\.com/
        bucket = $1
        _, key = env['PATH_INFO'].split('/', 2)
      else
        _, bucket, key = env['PATH_INFO'].split('/', 3)
      end

      return Errors.not_found unless bucket && key

      req = {bucket: bucket, key: key}

      req[:if_match] = env['HTTP_IF_MATCH'] if env['HTTP_IF_MATCH']
      req[:if_none_match] = env['HTTP_IF_NONE_MATCH'] if env['HTTP_IF_NONE_MATCH']
      req[:if_modified_since] = env['HTTP_IF_MODIFIED_SINCE'] if env['HTTP_IF_MODIFIED_SINCE']
      req[:if_unmodified_since] = env['HTTP_IF_UNMODIFIED_SINCE'] if env['HTTP_UNMODIFIED_SINCE']

      case env['REQUEST_METHOD']
      when 'HEAD'
        head = s3.head_object(req)
        return Errors.not_found unless head

        gentle env, req, head
      when 'GET'
        if env['rack.hijack?']
          hijack env, req

        else
          head = s3.head_object(req)
          return Errors.not_found unless head

          gentle env, req, head
        end
      end

    rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
      return Errors.not_found

    rescue Aws::S3::Errors::NotModified
      return Errors.not_modified

    rescue Aws::S3::Errors::PreconditionFailed
      return Errors.precondition_failed

    rescue NameError => e
      # https://github.com/aws/aws-sdk-core-ruby/pull/65
      raise e unless e.message == "wrong constant name 412Error"

      return Errors.precondition_failed
    end

    private

    def hijack(env, request)
      env['rack.hijack'].call
      out = env['rack.hijack_io']

      uri = URI.parse("#{endpoint}/#{request[:bucket]}/#{request[:key]}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        req = Net::HTTP::Get.new(uri)
        req['Connection'] = 'close'

        {
          if_match: 'If-Match'.freeze, if_none_match: 'If-None-Match'.freeze,
          if_modified_since: 'If-Modified-Since'.freeze, if_unmodified_since: 'If-Unmodified-Since'.freeze,
        }.each do |key, name|
          req[name] = request[key] if request[key]

        end
        req.delete 'Accept-Encoding'

        signer.sign_http_request(req)

        http.request(req) do |response|
          begin
            out.write "HTTP/1.1 #{response.code} #{response.message}\r\n"
            out.write "Status: #{response.code}\r\n"
            out.write "Connection: close\r\n"
            out.write "Content-Type: #{response['content-type']}\r\n" if response['content-type']
            out.write "Content-Length: #{response['content-length']}\r\n" if response['content-length']
            out.write "Transfer-Encoding: #{response['transfer-encoding']}\r\n" if response['transfer-encoding']
            out.write "ETag: #{response['etag']}\r\n" if response['etag']
            out.write "Last-Modified: #{response['last-modified']}\r\n" if response['last-modified']
            out.write "\r\n"

            # Hijack!
            buffered_io = response.instance_variable_get(:@socket)
            if buffered_io.is_a?(Net::BufferedIO)
              out.write buffered_io.instance_variable_get(:@rbuf)
              io = buffered_io.io
            else
              io = buffered_io
            end

            unless io.closed?
              IO.copy_stream io, out
            end
          ensure
            out.close unless out.closed?
          end
        end
      end


      return [200, {}, ['']]
    end

    def gentle(env, request, head)
      case env['REQUEST_METHOD']
      when 'GET'
        fiber = Fiber.new do
          s3.get_object(request) do |chunk|
            Fiber.yield(chunk)
          end
          Fiber.yield(nil)
        end

        body = Enumerator.new do |y|
          while n = fiber.resume
            y << n
          end
        end
      when 'HEAD'
        body = ['']
      end

      headers = {
        'Content-Type' => head.content_type,
        'Content-Length' => head.content_length.to_s,
        'Last-Modified' => head.last_modified,
        'ETag' => head.etag,
      }

      [200, headers, body]
    end

    def s3
      @s3 ||= Aws::S3::Client.new(@options)
    end

    def signer
      Aws4Signer.new(
        signer_credential.access_key_id,
        signer_credential.secret_access_key,
        s3.config.region,
        's3',
        security_token: signer_credential.session_token
      )
    end

    def signer_credential
      @credential ||= @options[:credentials] || Aws::CredentialProviderChain.new(s3.config).resolve
    end

    def endpoint
      s3.config.endpoint
    end

    module Errors
      class << self
        def method_not_allowed
          [405, {'Content-Type' => 'text/plain'}, ["method not allowed"]]
        end

        def not_found
          [404, {'Content-Type' => 'text/plain'}, ["not found"]]
        end

        def forbidden
          [403, {'Content-Type' => 'text/plain'}, ["forbidden"]]
        end

        def precondition_failed
          [412, {'Content-Type' => 'text/plain'}, ["precondition failed"]]
        end

        def not_modified
          [304, {'Content-Type' => 'text/plain'}, ["not modified"]]
        end

        def unknown(code)
          [code, {'Content-Type' => 'text/plain'}, ["Error: #{code}"]]
        end
      end
    end
  end
end
