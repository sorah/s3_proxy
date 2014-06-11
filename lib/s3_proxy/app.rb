require 'aws-sdk-core'
require 'stringio'

module S3Proxy
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

      head = s3.head_object(req)

      return Errors.not_found unless head

      case env['REQUEST_METHOD']
      when 'HEAD'
        gentle env, req, head
      when 'GET'
        if env['rack.hijack?']
          hijack env, req, head
        else
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

    def hijack(env, request, head)
      env['rack.hijack'].call

      io = env['rack.hijack_io']
      begin
        io.write "HTTP/1.1 200 OK\r\n"
        io.write "Status: 200\r\n"
        io.write "Connection: close\r\n"
        io.write "Content-Type: #{head.content_type}\r\n"
        io.write "Content-Length: #{head.content_length}\r\n"
        io.write "ETag: #{head.etag}\r\n"
        io.write "Last-Modified: #{head.last_modified}\r\n"
        io.write "\r\n"
        io.flush

        s3.get_object(request, target: io)
      ensure
        io.close
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
      @s3 ||= Aws::S3.new(@options)
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
