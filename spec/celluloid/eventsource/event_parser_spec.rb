require 'spec_helper'

RSpec.describe Celluloid::EventSource::EventParser do
  it 'converts lines to events' do
    lines =  <<LINES
id: 123
event: my-event
data: my-data

LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, false, ->(r) {}).to_a
    expect(events.length).to eq 1
    expect(events[0].id).to eq '123'
    expect(events[0].type).to eq 'my-event'.to_sym
    expect(events[0].data).to eq 'my-data'
  end

  it 'ignores comments' do
    lines =  <<LINES
: comment
id: 123
event: my-event
data: my-data


LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, false, ->(r) {}).to_a
    expect(events.length).to eq 1
    expect(events[0].id).to eq '123'
  end

  it 'resets values after each event' do
    lines =  <<LINES
id: 123
event: my-event
data: my-data

event: my-event2
data: my-data2

LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, false, ->(r) {}).to_a
    expect(events.length).to eq 2
    expect(events[0].id).to eq '123'
    expect(events[0].type).to eq 'my-event'.to_sym
    expect(events[0].data).to eq 'my-data'
    expect(events[1].id).to eq ''
    expect(events[1].type).to eq 'my-event2'.to_sym
    expect(events[1].data).to eq 'my-data2'
  end

  it 'sets the default event type to message' do
    lines =  <<LINES
data: my-data

LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, false, ->(r) {}).to_a
    expect(events.length).to eq 1
    expect(events[0].id).to eq ''
    expect(events[0].type).to eq :message
    expect(events[0].data).to eq 'my-data'
  end

  it 'does not generate events unless data is provided' do
    lines =  <<LINES
event: my-event

LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, false, ->(r) {}).to_a
    expect(events.length).to eq 0
  end

  it 'extends data with unprefixed lines as data in chunked mode' do
    lines =  <<LINES
data:
my-data

LINES
    events = Celluloid::EventSource::EventParser.new(lines.lines, true, ->(r) {}).to_a
    expect(events.length).to eq 1
    expect(events[0].id).to eq ''
    expect(events[0].type).to eq :message
    expect(events[0].data).to eq 'my-data'
  end

  it 'reports retry updates to the provided function' do
    lines =  <<LINES
retry: 123
LINES
    received_retry_args = []
    set_retry = lambda { |r| received_retry_args << r }
    events = Celluloid::EventSource::EventParser.new(lines.lines, true, set_retry).to_a
    expect(received_retry_args).to eq [123]
    expect(events.length).to eq 0
  end

end
