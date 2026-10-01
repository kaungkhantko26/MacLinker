cask "maclinker" do
  version "1.2.2"
  sha256 "f63cf3625393426b3576a247e4801fa859cb2fd3a92eed111b6631d132f83f7f"

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
