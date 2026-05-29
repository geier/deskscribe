cask "deskscribe" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256"

  url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
  name "DeskScribe"
  desc "Menu bar dictation app using local NeMo ASR"
  homepage "https://github.com/geier/deskscribe"

  depends_on macos: ">= :ventura"

  app "DeskScribe.app"

  caveats <<~EOS
    DeskScribe runs local speech recognition and may download the NeMo model
    on first use. Grant Microphone and Accessibility permissions when prompted.
  EOS
end
