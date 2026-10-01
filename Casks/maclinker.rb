cask "maclinker" do
  version "1.2.3"
  sha256 "aa44f4a0091d7c4e9f2cb67e3a7ba5c84dcf24f687451deaf403ff7ad93dbd0b"

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
