#!/bin/bash

# ======================================================
#  Slim 4 API Setup Script (PHP 8.1+)
#  Includes PDO, php-di, symfony/console, monolog,
#  respect/validation, PostgreSQL (default), and CLI Kernel
# ======================================================

set -e

PROJECT_NAME=${1:-"my-api"}

echo "🚀 Setting up project: $PROJECT_NAME ..."

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# ------------------------------------------------------
# Folder Structure
# ------------------------------------------------------
echo "📂 Creating folder structure..."
mkdir -p public app/{Controllers,Services,Routes,Helpers,DataAccess/{Contracts,Adapters,Repositories}} \
         Kernel/{Console/Commands,Database,Security,Validation} \
         bootstrap configs database/migrations docs storage/logs bin vendor

# ------------------------------------------------------
# .env
# ------------------------------------------------------
echo "🧾 Creating .env..."
cat > .env <<EOF
APP_ENV=local
APP_DEBUG=true
APP_NAME="${PROJECT_NAME} API"
DB_DRIVER=pgsql
DB_HOST=localhost
DB_PORT=5432
DB_DATABASE=localdb
DB_USERNAME=root
DB_PASSWORD=root
JWT_SECRET=your_jwt_secret_here
EOF

# ------------------------------------------------------
# composer.json
# ------------------------------------------------------
echo "📦 Creating composer.json..."
cat > composer.json <<'EOF'
{
  "require": {
    "php": "^8.1",
    "slim/slim": "^4.13",
    "slim/psr7": "^1.6",
    "vlucas/phpdotenv": "^5.6",
    "php-di/php-di": "^7.0",
    "monolog/monolog": "^3",
    "symfony/console": "^7.1",
    "respect/validation": "^2.2"
  },
  "autoload": {
    "psr-4": {
      "App\\": "app/",
      "Kernel\\": "Kernel/",
      "Database\\": "database/"
    },
    "files": [
      "Kernel/helpers.php"
    ]
  }
}
EOF

# ------------------------------------------------------
# public/index.php
# ------------------------------------------------------
echo "⚙️ Creating Slim entrypoint..."
cat > public/index.php <<EOF
<?php
declare(strict_types=1);

use Slim\Factory\AppFactory;
use Dotenv\Dotenv;

require __DIR__ . '/../vendor/autoload.php';

// Load environment
\$dotenv = Dotenv::createImmutable(__DIR__ . '/../');
\$dotenv->load();

// Bootstrap the app
\$app = require __DIR__ . '/../bootstrap/app.php';

// Register routes
(require __DIR__ . '/../app/Routes/routes.php')(\$app);

\$app->run();
EOF

# ------------------------------------------------------
# bootstrap/Container.php
# ------------------------------------------------------
echo "🧱 Creating Container..."
cat > bootstrap/Container.php <<EOF
<?php
use DI\ContainerBuilder;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use App\DataAccess\DatabaseFactory;

\$containerBuilder = new ContainerBuilder();

\$containerBuilder->addDefinitions([
    Logger::class => function () {
        \$logger = new Logger('${PROJECT_NAME}');
        \$logger->pushHandler(new StreamHandler(__DIR__ . '/../storage/logs/app.log', Logger::DEBUG));
        return \$logger;
    },
    PDO::class => function () {
        \$factory = new DatabaseFactory();
        return \$factory->createAdapter();
    }
]);

return \$containerBuilder->build();
EOF

# ------------------------------------------------------
# bootstrap/app.php
# ------------------------------------------------------
echo "🧩 Creating bootstrap/app.php..."
cat > bootstrap/app.php <<EOF
<?php
declare(strict_types=1);

use Slim\Factory\AppFactory;
use Dotenv\Dotenv;

// Load Composer
require_once __DIR__ . '/../vendor/autoload.php';

// Load .env
if (file_exists(__DIR__ . '/../.env')) {
    \$dotenv = Dotenv::createImmutable(__DIR__ . '/../');
    \$dotenv->load();
}

// Build Container
\$container = require __DIR__ . '/Container.php';
AppFactory::setContainer(\$container);

// Create Slim app
\$app = AppFactory::create();

// Return both for reuse (web/CLI)
return \$app;
EOF

# ------------------------------------------------------
# Routes and Controllers
# ------------------------------------------------------
echo "🧠 Creating base routes and controllers..."

cat > app/Routes/routes.php <<EOF
<?php
use Slim\App;
use App\Controllers\AuthController;
use App\Controllers\UserController;

return function (App \$app) {
    \$app->get('/', function (\$request, \$response) {
        \$data = ['status' => 'ok', 'message' => '${PROJECT_NAME} API is running'];
        \$response->getBody()->write(json_encode(\$data));
        return \$response->withHeader('Content-Type', 'application/json');
    });

    \$app->get('/users', [UserController::class, 'index']);
    \$app->post('/auth/login', [AuthController::class, 'login']);
};
EOF

cat > app/Helpers/ResponseHelper.php <<'EOF'
<?php
namespace App\Helpers;

class ResponseHelper
{
    public static function json($response, $data, int $status = 200)
    {
        $response->getBody()->write(json_encode($data));
        return $response->withStatus($status)->withHeader('Content-Type', 'application/json');
    }
}
EOF

cat > app/Controllers/AuthController.php <<'EOF'
<?php
namespace App\Controllers;

use App\Helpers\ResponseHelper;

class AuthController
{
    public function login($request, $response)
    {
        $params = (array)$request->getParsedBody();
        $data = [
            'status' => 'success',
            'message' => 'User logged in successfully',
            'user' => $params['username'] ?? 'guest'
        ];
        return ResponseHelper::json($response, $data);
    }
}
EOF

cat > app/Controllers/UserController.php <<'EOF'
<?php
namespace App\Controllers;

use App\Helpers\ResponseHelper;

class UserController
{
    public function index($request, $response)
    {
        $users = [
            ['id' => 1, 'name' => 'John Doe'],
            ['id' => 2, 'name' => 'Jane Smith']
        ];
        return ResponseHelper::json($response, ['users' => $users]);
    }
}
EOF

# ------------------------------------------------------
# bin/console
# ------------------------------------------------------
echo "🧩 Creating CLI Console..."
cat > bin/console <<EOF
#!/usr/bin/env php
<?php
require __DIR__ . '/../vendor/autoload.php';

use Symfony\Component\Console\Application;

// Bootstrap Slim app and container
\$app = require __DIR__ . '/../bootstrap/app.php';
\$container = \$app->getContainer();

// Initialize Symfony Console
\$application = new Application('${PROJECT_NAME} CLI', '1.0.0');

// Load CLI Kernel (you can expand with commands)
if (class_exists('Kernel\\Console\\Kernel')) {
    \$kernel = new Kernel\\Console\\Kernel(\$application, \$app, \$container);
    \$kernel->register();
}

\$application->run();
EOF

chmod +x bin/console

# ------------------------------------------------------
# Configs
# ------------------------------------------------------
echo "🧾 Adding configs..."
cat > configs/app.php <<EOF
<?php
return [
    'name' => \$_ENV['APP_NAME'] ?? '${PROJECT_NAME} API',
    'env' => \$_ENV['APP_ENV'] ?? 'production',
    'debug' => \$_ENV['APP_DEBUG'] ?? false,
];
EOF

cat > configs/database.php <<'EOF'
<?php
return [
    'driver' => $_ENV['DB_DRIVER'] ?? 'pgsql',
    'host' => $_ENV['DB_HOST'] ?? 'localhost',
    'port' => $_ENV['DB_PORT'] ?? '5432',
    'database' => $_ENV['DB_DATABASE'] ?? 'localdb',
    'username' => $_ENV['DB_USERNAME'] ?? 'root',
    'password' => $_ENV['DB_PASSWORD'] ?? 'root',
];
EOF

# ------------------------------------------------------
# Final Message
# ------------------------------------------------------
echo ""
echo "✅ ${PROJECT_NAME} structure created successfully!"
echo ""
echo "Next steps:"
echo "---------------------------------------"
echo "cd ${PROJECT_NAME}"
echo "composer install"
echo "php -S localhost:8080 -t public"
echo ""
echo "or run CLI:"
echo "./bin/console"
echo ""
echo "Then open: http://localhost:8080"
echo "🎉 Enjoy your new Slim 4 + PHP-DI ${PROJECT_NAME} API"
