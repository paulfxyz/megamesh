<?php
// Minimal PSR-4 autoloader for the vendored libraries (no composer on shared hosting).
spl_autoload_register(function (string $class): void {
    $map = [
        'phpseclib4\\' => __DIR__ . '/phpseclib/',
        'ParagonIE\\ConstantTime\\' => __DIR__ . '/constant_time_encoding/src/',
    ];
    foreach ($map as $prefix => $dir) {
        if (str_starts_with($class, $prefix)) {
            $file = $dir . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
            if (is_file($file)) { require $file; }
            return;
        }
    }
});
require __DIR__ . '/phpseclib/bootstrap.php';
