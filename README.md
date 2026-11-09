# QuietExtract

QuietExtract is a native, ad-free macOS archive utility. All operations run locally.

- **Extract** ZIP, RAR, 7z, tar.gz, tgz, and tar. Password-protected ZIP, RAR, and 7z prompt for a password. For numbered ZIP and 7z volumes or part-numbered RAR volumes, keep the parts together and select or drop a volume.
- **Compress** files and folders to ZIP or 7z. Choose the compression level, optional password, volume size, and destination. Encrypted ZIP defaults to AES-256 and offers legacy ZipCrypto. Encrypted 7z uses AES-256 and can encrypt filenames. Creating encrypted ZIP requires a password of up to 99 printable ASCII characters.
- **Verify** checks an archive's integrity without extracting it. A separate option verifies newly compressed files before they are published. Split outputs and separate archives are grouped into their own output folder.
- Options include excluding Mac resource files, archiving each selected item separately, and moving originals to Trash after verification. The Trash option is off by default.

Drop items onto the window or use the file picker. To associate an archive type with Finder double-click, select a sample, open **Get Info**, select QuietExtract under **Open with**, and click **Change All**. Results are saved under an unused name. Links and special files are outside the supported extraction scope.

## Install on macOS

Requires an Apple silicon Mac, macOS 14 or later, and the Xcode Command Line Tools. If the tools are missing, run `xcode-select --install` and complete the macOS installer first.

```sh
git clone https://github.com/dennisge/QuietExtract.git
cd QuietExtract
./build.sh
open .build
```

The first build downloads 7-Zip 26.06 from its official release and verifies its SHA-256 checksum. The script builds and locally signs `.build/QuietExtract.app`. In Finder, drag the app into **Applications**, then open it from there. If you are replacing an existing copy, quit it first. A local build does not require a paid Apple Developer account. QuietExtract runs offline after installation.

## Run the tests

With Python 3 installed, run `./test.sh` on the Mac to test extraction, compression, encryption, splitting, and verification. Run the script in a regular Terminal session because it uses macOS `sandbox-exec` for archive operations that need restricted write access.

## License

QuietExtract's original code and documentation are under the [MIT License](LICENSE). Third-party components retain their own terms:

- The build fetches [7-Zip 26.06](https://github.com/ip7z/7zip/releases/tag/26.06) from upstream. See the [7-Zip license notice](Vendor/7zip/License.txt).
- The libarchive headers and RAR5 fixtures come from [libarchive](https://github.com/libarchive/libarchive). The encrypted fixture is from v3.8.5 and the others are from v3.7.4. See the [libarchive license](Sources/CArchive/COPYING).
