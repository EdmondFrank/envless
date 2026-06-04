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
  version "0.2.1"
  license "Apache-2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-macos.tar.gz"
      sha256 "bd5a7342ec1d05818e16a8377ec639206c82d0317b1259436328dee92bd51f18"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-macos.tar.gz"
      sha256 "83df776d32c1697f125c95be08682733aec54250451e23bb8adaf07901e66a84"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-linux-gnu.tar.gz"
      sha256 "f99fc44c518770201245f141cba5d9ebb2fb1cc289265c88255eb549a5ab103e"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-linux-gnu.tar.gz"
      sha256 "4e7236ab60db49ae5ebbd13f3e2ada7b5800d3a9f044377100aa1f40bc383033"
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
