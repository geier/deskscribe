cask "deskscribe" do
  version "0.1.0"
  sha256 "3063760e73af2f09a50585be1e686a600d881e6abe750903bbc8f2bc2a9d703e"

  url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
  name "DeskScribe"
  desc "Menu bar dictation app using local native ONNX ASR"
  homepage "https://github.com/geier/deskscribe"

  depends_on macos: ">= :ventura"

  app "DeskScribe.app"

  caveats <<~EOS
    DeskScribe runs local speech recognition and downloads the selected model
    automatically the first time it is needed.

    Grant Microphone and Accessibility permissions when prompted.
  EOS
end
