cask "deskscribe" do
  version "0.1.1"
  sha256 "79b9692cb72c8a8ad4db8a3f6b78d4f91e86d2323bf7676ef52946163d5caca5"

  url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
  name "DeskScribe"
  desc "Menu bar dictation app using local speech recognition"
  homepage "https://github.com/geier/deskscribe"

  depends_on macos: :ventura

  app "DeskScribe.app"

  caveats <<~EOS
    DeskScribe runs local speech recognition and downloads the selected model
    automatically the first time it is needed.

    Grant Microphone and Accessibility permissions when prompted.
  EOS
end
