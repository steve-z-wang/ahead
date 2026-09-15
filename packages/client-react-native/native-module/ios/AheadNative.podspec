Pod::Spec.new do |s|
  s.name = 'AheadNative'
  s.version = '0.1.0'
  s.summary = 'Ahead native mobile carrier'
  s.description = 'Expo module that carries Ahead JSON calls into the Rust runtime.'
  s.license = { :type => 'Proprietary' }
  s.author = 'Ahead contributors'
  s.homepage = 'https://github.com/zanminwang/ahead'
  s.platform = :ios, '15.1'
  s.source = { :path => '.' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  # Lives under ios/ so that Expo autolinking registers the module class.
  s.source_files = '**/*.{h,swift}'
  s.exclude_files = 'Tests/**/*'
  s.public_header_files = 'AheadNative.h'
  s.vendored_libraries = 'lib/libahead_mobile.a'
  # The vendored Rust library carries the arm64 simulator slice only.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64'
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64'
  }
end
