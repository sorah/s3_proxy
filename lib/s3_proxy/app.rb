require 'aws-sdk-core'
require 'stringio'

module S3Proxy
  class App
    def initialize(options={})
      @options = options
    end

    def call(env)
      return Errors.method_not_allowed unless env['REQUEST_METHOD'] == 'GET'
      return Errors.not_found if env['PATH_INFO'].empty?

      # When used as a forward proxy
      if env['HTTP_HOST'] =~ /(.+)\.s3\.amazonaws\.com/
        bucket = $1
        _, key = env['PATH_INFO'].split('/', 2)
      else
        _, bucket, key = env['PATH_INFO'].split('/', 3)
      end
      path = {bucket: bucket, key: key}

      head = s3.head_object(path)
      return Errors.not_found unless head

      if env['rack.hijack?']
        hijack env, path, head
      else
        gentle env, path, head
      end

    rescue Aws::S3::Errors::NoSuchKey
      return Errors.not_found
    end

    private

    def hijack(env, path, head)
      env['rack.hijack'].call

      io = env['rack.hijack_io']
      begin
        io.write "HTTP/1.1 200 OK\r\n"
        io.write "Status: 200\r\n"
        io.write "Connection: close\r\n"
        io.write "Content-Type: #{head.content_type}\r\n"
        io.write "Content-Length: #{head.content_length}\r\n"
        io.write "ETag: #{head.etag}\r\n"
        io.write "\r\n"
        io.flush

        s3.get_object(path, target: io)
      ensure
        io.close
      end
      return [200, {}, ['']]
    end

    def gentle(env, path, head)
      fiber = Fiber.new do
        s3.get_object(path) do |chunk|
          Fiber.yield(chunk)
        end
        Fiber.yield(nil)
      end

      body = Enumerator.new do |y|
        while n = fiber.resume
          y << n
        end
      end

      [200, {'Content-Type' => head.content_type, 'Content-Length' => head.content_length.to_s}, body]
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

        def unknown(code)
          [code, {'Content-Type' => 'text/plain'}, ["Error: #{code}"]]
        end
      end
    end
  end
end
