cask "dictat" do
  version :latest
  sha256 :no_check

  url "https://github.com/Otnakp/dictat/releases/latest/download/Dictat.zip"
  name "Dictat"
  desc "Push-to-talk dictation in the menu bar, powered by Apple Speech (on-device)"
  homepage "https://github.com/Otnakp/dictat"

  # Sparkle gestisce gli aggiornamenti in-app.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Dictat.app"

  zap trash: [
    "~/Library/Preferences/com.local.dictat.plist",
  ]
end
