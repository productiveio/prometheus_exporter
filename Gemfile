# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Dev libs
gem "appraisal", git: "https://github.com/thoughtbot/appraisal.git"
gem "activerecord", "~> 7.1"
gem "bundler", ">= 2.1.4"
gem "m"
gem "mini_racer"
# minitest 6.0 removed Minitest::Mock and #stub, which the collector tests rely on.
gem "minitest", "< 6.0"
gem "minitest-stub-const"
gem "oj"
gem "rack-test"
gem "rake"
gem "redis"
gem "syntax_tree"
gem "syntax_tree-disable_ternary"
gem "raindrops", "~> 0.19" if !RUBY_ENGINE == "jruby"

# Dev tools / linter
gem "guard", require: false
gem "guard-minitest", require: false
gem "rubocop", require: false
gem "rubocop-discourse", require: false
