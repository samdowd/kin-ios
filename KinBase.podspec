#
# Be sure to run `pod lib lint KinBase.podspec' to ensure this is a
# valid spec before submitting.
#

#
# Spec for KinBase
#
Pod::Spec.new do |s|
  s.name             = 'KinBase'
  s.version          = '0.1.0'
  s.summary          = 'Kin SDK for iOS'

  s.description      = <<-DESC
    Use the Kin SDK for iOS to enable the use of Kin inside of your app. Include only the functionality you need to provide the right experience to your users. Use just the base library to access the lightest-weight wrapper over the Kin crytocurrency.
                       DESC

  s.homepage         = 'https://github.com/kinecosystem/kin-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Kik Engineering' => 'engineering@kik.com' }
  s.source           = { :git => 'https://github.com/kinecosystem/kin-ios.git', :tag => "#{s.version}" }

  s.ios.deployment_target = '9.0'
  s.swift_version = '5.0'

  non_arc_files = 'KinBase/KinBase/Src/Storage/Gen/*.{h,m}'
  s.source_files = 'KinBase/KinBase/**/*.{h,swift}'

  s.dependency 'kin-stellar-ios-mac-sdk'
  s.dependency 'PromisesSwift', '~> 1.2.8'

  s.requires_arc = true

  s.subspec 'no-arc' do |sna|
    sna.requires_arc = false
    sna.source_files = non_arc_files
    sna.dependency 'Protobuf', '~> 3.0'
  end

end