# S3Proxy - simple rack app, proxies to Amazon S3

## Features

- Simple Rack application that proxies GET requests to Amazon S3
- Rack Hijacking support

## Installation

Add this line to your application's Gemfile:

    gem 's3_proxy'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install s3_proxy

## Usage

### config.ru

``` ruby
require 's3_proxy'
run S3Proxy::App.new
```

``` ruby
# you can pass option to Aws::S3.new
run S3Proxy::App.new(credentials: Aws::InstanceProfileCredentials.new)
```

### requesting

```
$ curl http://app/foo/bar
(returns key `bar` in bucket named `foo`)
```

## Contributing

1. Fork it ( https://github.com/[my-github-username]/s3_proxy/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
