# Celluloid::Eventsource

[![Gem Version](https://badge.fury.io/rb/celluloid-eventsource.png)](http://badge.fury.io/rb/ld-celluloid-eventsource) [![CircleCI](https://circleci.com/gh/launchdarkly/celluloid-eventsource/tree/master.svg?style=svg)](https://circleci.com/gh/launchdarkly/celluloid-eventsource/tree/master)

An EventSource client based off Celluloid::IO.

Specification based on [EventSource](http://www.w3.org/TR/2012/CR-eventsource-20121211/)

## Installation

Add this line to your application's Gemfile:

    gem 'ld-celluloid-eventsource'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install celluloid-eventsource

then somewhere in your project:

    require 'celluloid/eventsource'

## Usage

Initializing a new `Celluloid::EventSource` object will create the connection:

```ruby
es = Celluloid::EventSource.new("http://example.com/")
```

Messages can be received on events such as `on_open`, `on_message` and `on_error`.

These can be assigned at initialize time

```ruby
es = Celluloid::EventSource.new("http://example.com/") do |conn|
  conn.on_open do
    puts "Connection was made"
  end

  conn.on_message do |event|
    puts "Message: #{event.data}"
  end

  conn.on_error do |message|
    puts "Response status #{message[:status_code]}, Response body #{message[:body]}"
  end

  conn.on(:time) do |event|
    puts "The time is #{event.data}"
  end
end
```

To close the connection `#close` will shut the socket connection but keep the actor alive.

### Event Handlers

Event handlers should be added when initializing the eventsource.

**Warning**
To change event handlers after initializing there is a [Gotcha](https://github.com/celluloid/celluloid/wiki/Gotchas).
Celluloid sends messages to actors through thread-safe proxies.

To get around this, use `wrapped_object` to set the handler on the actor but be aware of the concequences.

```ruby
es.wrapped_object.on_messsage { |message| puts "Different #{message}" }
```

This same concept applies for changing the `url` of the eventsource.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

