# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 's3_proxy/version'

Gem::Specification.new do |spec|
  spec.name          = "s3_proxy"
  spec.version       = S3Proxy::VERSION
  spec.authors       = ["Shota Fukumori (sora_h)"]
  spec.email         = ["her@sorah.jp"]
  spec.summary       = %q{S3 reverse proxy rack app that accepts multiple buckets}
  spec.description   = %q{S3 reverse proxy rack app that accepts multiple buckets.}
  spec.homepage      = "https://github.com/sorah/s3_proxy"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "rack", "~> 1.5.2"
  spec.add_runtime_dependency "aws-sdk-core", "2.0.0.rc8"

  spec.add_development_dependency "bundler", "~> 1.6"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "puma"
end
