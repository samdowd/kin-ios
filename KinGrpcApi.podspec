Pod::Spec.new do |s|
  s.name     = 'KinGrpcApi'
  s.version  = '0.2.0'
  s.license  = { :type => 'MIT', :file => 'LICENSE' }
  s.authors  = { 'Kik Engineering' => 'engineering@kik.com' }
  s.homepage = 'https://github.com/kinecosystem/kin-ios'
  s.summary = 'Grpc Api for Kin SDK iOS'
  s.source = { :git => 'https://github.com/kinecosystem/kin-ios.git' }

  s.ios.deployment_target = '9.0'

  # Base directory where the .proto files are.
  src = 'KinGrpcApi/proto'

  # We'll use protoc with the gRPC plugin.
  s.dependency '!ProtoCompiler-gRPCPlugin', '~> 1.28.0'

  # Pods directory corresponding to this app's Podfile, relative to the location of this podspec.
  pods_root = '../Pods'

  # Path where Cocoapods downloads protoc and the gRPC plugin.
  protoc_dir = "#{pods_root}/\!ProtoCompiler"
  protoc = "#{protoc_dir}/protoc"
  plugin = "#{pods_root}/\!ProtoCompiler-gRPCPlugin/grpc_objective_c_plugin"

  # Directory where you want the generated files to be placed. This is an example.
  dir = "KinGrpcApi/gen"

  # Run protoc with the Objective-C and gRPC plugins to generate protocol messages and gRPC clients.
  # You can run this command manually if you later change your protos and need to regenerate.
  # Alternatively, you can advance the version of this podspec and run `pod update`.

  # Only run when there is proto upgrade
  #s.prepare_command = <<-CMD
  #  ./KinGrpcApi/generate_protos.sh
  #CMD

  # The --objc_out plugin generates a pair of .pbobjc.h/.pbobjc.m files for each .proto file.
  s.subspec 'Messages' do |ms|
    ms.source_files = "#{dir}/*.pbobjc.{h,m}", "#{dir}/**/*.pbobjc.{h,m}"
    ms.header_mappings_dir = dir
    ms.requires_arc = false
    # The generated files depend on the protobuf runtime.
    ms.dependency 'Protobuf', '~> 3.11.4'
  end

  # The --objcgrpc_out plugin generates a pair of .pbrpc.h/.pbrpc.m files for each .proto file with
  # a service defined.
  s.subspec 'Services' do |ss|
    ss.source_files = "#{dir}/*.pbrpc.{h,m}", "#{dir}/**/*.pbrpc.{h,m}"
    ss.header_mappings_dir = dir
    ss.requires_arc = true
    # The generated files depend on the gRPC runtime, and on the files generated by `--objc_out`.
    ss.dependency 'gRPC-ProtoRPC', '~> 1.28.0'
    ss.dependency "#{s.name}/Messages"
  end

  s.pod_target_xcconfig = {
    # This is needed by all pods that depend on Protobuf:
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GPB_USE_PROTOBUF_FRAMEWORK_IMPORTS=1',
    # This is needed by all pods that depend on gRPC-RxLibrary:
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    # This is needed for the user Podfile to use_framework! https://github.com/CocoaPods/CocoaPods/issues/4605
    'USE_HEADERMAP' => 'NO',
    'ALWAYS_SEARCH_USER_PATHS' => 'NO',
    'USER_HEADER_SEARCH_PATHS' => '$(PODS_ROOT)/KinGrpcApi/KinGrpcApi/gen',
    'HEADER_SEARCH_PATHS' => '$(PODS_ROOT)/KinGrpcApi/KinGrpcApi/gen'

  }
end