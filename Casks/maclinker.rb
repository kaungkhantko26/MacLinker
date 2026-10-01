cask "maclinker" do
  version "1.5.1"
  sha256 "d034be9e380dfa76854d5fb6f486c1f3e0e99429219763dffc5f346a6845e600"

  url "https://github.com/kaungkhantko26/MacLinker/releases/download/v#{version}/MacLinker.zip"
  name "MacLinker"
  desc "Share keyboard, mouse, clipboard and files between Macs"
  homepage "https://github.com/kaungkhantko26/MacLinker"

  depends_on macos: ">= :ventura"

  app "MacLinker.app"

  # The app isn't notarized by Apple, so clear the download quarantine flag.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/MacLinker.app"]
  end

  zap trash: [
    "~/Library/Application Support/MacLinker",
    "~/Library/Logs/MacLinker-update.log",
    "~/Library/Preferences/com.maclinker.app.plist",
    "~/Downloads/MacLinker",
  ]
end
