# proxybricks
Building blocks for a very simple HTTP proxy / web server on Ruby

# Motivation

I wrote it while working on an JavaScript browser app that needs to call JIRA REST API.
The server I was using did not send any of the CORS headers (like `Access-Control-Allow-Origin`)
so it was not possible to call it from an HTML loaded from the local file system because
of the same-origin policy. Also, it was JIRA 6.something with JSONP support already removed
so I could not think of other options other than proxying requests to it through
the same server that was used to load HTML. So I needed something that serves as both
web server for my HTML pages and a sort of a proxy that can relay requests to JIRA
as a temporary solutuib until admins can configure JIRA with proper CORS headers.

## What is proxybricks

It is not an ready to use application but a small library you can use to create your simple web server / proxy server. Mostly for testing purposes.

## Simple web server

```ruby
require_relative 'proxybricks.rb'

server = Server.new(8080)
server.add_handler '/', StaticFilesRequestHandler.new(File.dirname(__FILE__))
server.run
```

`add_handler` above adds a handler for server root URL (/) that just serves static files from the directory of the script itself and its subdirectories.
You can test it with 

```
curl http://localhost:8080/proxybricks.rb
```

## Simple proxy

```ruby
require_relative 'lib/proxybricks.rb'

server = Server.new(8080)
server.add_handler '/', ProxyingRequestHandler.new('target.domain.com', 443)
server.run
```

Any request to `http://localhost:8080/path` will be relayed to `https://target.domain.com/path` and response returned to the client.

Note that ProxyingRequestHandler only translates to HTTPS targets. If you need HTTP, you can fix it by creating a subclass
and overriding its `connect_target` method.


## Combining them together

`add_handler` allows you to add multiple handlers, they will be checked in the order they were added and the first handler
with path being the prefix of URI requested will be invoked.

```ruby
require_relative 'lib/proxybricks.rb'

server = Server.new(8080)
server.add_handler '/static/', StaticFilesRequestHandler.new(File.dirname(__FILE__))
server.add_handler '/rest/', ProxyingRequestHandler.new('jira.domain.com', 443)
server.run
```

Note that prefix is not removed from the URI when it is passed to a handler, so the static content
handler from the example above will be receiving URIs like `/static/dir/test.html` and so you need directory `static`
to exist.
Similarly, if you make a request to `http://localhost:8080/rest/rest/auth/1/session`, the proxying handler will invoke `https://jira.domain.com/rest/rest/auth/1/session` keeping the `/rest` part.

## Modifying proxied request/response
Sometimes (or should I say often?) you will find yourself in a need to patch request or response headers.
To do that, you need to subclass ProxyingRequestHandler and override `modify_request` and/or `modify_response` methods.

```ruby
class TestRequestHandler < ProxyingRequestHandler

  def modify_request(request)
    super
    request.uri = request.uri.sub(%r{^/localpath/}, '/serverpath/')
    request.headers.remove('Referer')
  end

  def modify_response(response)
    super
    response.headers.remove('Set-Cookie')
  end

end

server = Server.new(8080)
server.add_handler '/localpath/', TestRequestHandler.new('server.domain.com', 443)
server.run
```

The `modify_request` in the example above will remove `Referer` header from the request before passing it to remote server
and change path prefix in the request URI. So a request to `http://localhost:8080/localpath/test1` will translate into `https://server.domain.com/serverpath/test1`

The `modify_response` just removes all cookies from the response before passing it to the client.


