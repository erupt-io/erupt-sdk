<?php

// PSR-4 autoloader for use without Composer: require __DIR__ . '/autoload.php';
spl_autoload_register(function (string $class): void {
    if (str_starts_with($class, 'Erupt\\')) {
        $file = __DIR__ . '/src/' . str_replace('\\', '/', substr($class, 6)) . '.php';
        if (is_file($file)) {
            require $file;
        }
    }
});
