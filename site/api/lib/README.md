# Vendored libraries (not committed)

The deployer needs [phpseclib 4](https://github.com/phpseclib/phpseclib) (`phpseclib/`) and
[paragonie/constant_time_encoding](https://github.com/paragonie/constant_time_encoding) (`constant_time_encoding/src/`)
next to `autoload.php`. Download the release tarballs and place them here before uploading `site/` to the host.
Shared hosting has no composer; `autoload.php` is a 15-line PSR-4 loader.
