cask "maclinker" do
  version "1.0.2"
  sha256 "00dd04e2121b5494e54c13512bbc7720e9a43969bd6c5a5bbd896ed89580dc7f"

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
