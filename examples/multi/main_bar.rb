# encoding: utf-8

require 'tty-progressbar'

bars = TTY::ProgressBar::Multi.new("main [:bar] :percent")

bar1 = bars.register "foo [:bar] :percent", total: 20
bar2 = bars.register "bar [:bar] :percent", total: 30
bar3 = bars.register "baz [:bar] :percent", total: 10

bars.start

th1 = Thread.new { 20.times { sleep(0.2); bar1.advance } }
th2 = Thread.new { 30.times { sleep(0.1); bar2.advance } }
th3 = Thread.new { 10.times { sleep(0.3); bar3.advance } }

[th1, th2, th3].each(&:join)
