# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'kitchen/driver/powervc_version'

Gem::Specification.new do |spec|
  spec.name          = 'kitchen-powervc'
  spec.version       = Kitchen::Driver::POWERVC_VERSION
  spec.authors       = ['Benoit Creau']
  spec.email         = ['benoit.creau@chmod666.org']
  spec.description   = 'A Test Kitchen Driver for Powervc'
  spec.summary       = spec.description
  spec.homepage      = 'https://github.com/chmod666org/kitchen-powervc'
  spec.license       = 'Apache 2.0'

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = []
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.1.0'

  spec.add_dependency 'test-kitchen', '~> 1.4', '>= 1.4.1'
  spec.add_dependency 'fog', '~> 1.33'
  spec.add_dependency 'unf'
  spec.add_dependency 'ohai'
  spec.add_dependency 'activesupport', '~> 4.2.7.1'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rubocop', '~> 0.36'
  spec.add_development_dependency 'cane'
  spec.add_development_dependency 'countloc'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'simplecov-console'
  spec.add_development_dependency 'coveralls'
  spec.add_development_dependency 'github_changelog_generator'
end
