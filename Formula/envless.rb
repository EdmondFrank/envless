# Homebrew formula for envless.
#
# Distribution model — self-tap. Users install via:
#   brew tap biliboss/envless https://github.com/biliboss/envless
#   brew install biliboss/envless/envless
#
# `version` + the four `sha256` lines are kept in sync with the
# matching release tarballs by `.github/workflows/release.yml`, which
# rewrites this file on every `v*` tag push. Hand-edits to those
# fields will be lost on the next release. The structural shape of
# the formula (deps, install, test, caveats) is hand-maintained.
#
# Audit:
#   brew audit --strict --tap biliboss/envless
#
class Envless < Formula
  desc "Agent-first secrets manager — encrypted dotenv files in git via sops+age"
  homepage "https://biliboss.github.io/envless/"
  version "0.0.2"
  license "Apache-2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-macos.tar.gz"
      sha256 "7419cf8691ae6759cabbdf5b4a199be4f9e17fd3423c219c0549aa3d0c5ead55"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-macos.tar.gz"
      sha256 "16518618fc5358af7456d4b031ceaec0f507d7afcd7c93986de058b13120319a"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-linux-gnu.tar.gz"
      sha256 "163953a9115752bc71e0c12907524e36f00ef90cc75985ba5f693d2ff4169f88"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-linux-gnu.tar.gz"
      sha256 "e9a89cddb4dd66ec419bff4fa02532d0de9af37aacd16f7bb7dee02b5e135288"
    end
  end

  # envless shells out to these two binaries; they are not bundled.
  depends_on "age"
  depends_on "sops"

  def install
    bin.install "envless"
  end

  def caveats
    <<~EOS
      envless requires `age` and `sops` on PATH. Both were just installed as
      dependencies of this formula.

      Initialise a repo:
        cd <your-project>
        envless init
        envless set OPENAI_API_KEY --env=dev
        envless exec --env=dev -- your-app

      Docs: https://biliboss.github.io/envless/
    EOS
  end

  test do
    assert_match "envless v#{version}", shell_output("#{bin}/envless --version")
  end
end
