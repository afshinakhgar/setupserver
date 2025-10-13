#!/bin/bash

# ======================================================
# Doob API Setup Script
# Author: ChatGPT (GPT-5)
# Description: Creates a complete Slim 4 API project 
# with PHP 8.1+, PDO, php-di, symfony/console, monolog,
# and respect/validation with PostgreSQL as default.
# ======================================================

set -e
PROJECT_NAME=${1:-"doob-api"}

echo "🚀 Setting up project: $PROJECT_NAME ..."

# Create base directory
mkdir -p $PROJECT_NAME
cd $PROJECT_NAME

# ------------------------------------------------------
# 1. Create folder structure
# ------------------------------------------------------

echo "📂 Creating folder structure..."

mkdir -p public app/Controllers app/DataAccess/{Contracts,Adapters,Repositories} \
         app/Services app/Routes app/Helpers \
         Kernel/{Console/Commands,Database,Security,Validation} \
         bootstrap configs database/migrations docs storage/logs bin vendor

# ------------------------------------------------------
# 2. Create .env file
# ------------------------------------------------------

echo "🧾 Creating .env..."

cat > .env <<'EOF'
APP_ENV=local
APP_DEBUG=true
APP_NAME="Doob API"
DB_DRIVER=pgsql
DB_HOST=localhost
DB_PORT=5432
DB_DATABASE=localdb
DB_USERNAME=root
DB_PASSWORD=root
JWT_SECRET=your_jwt_secret_here
EOF

# ------------------------------------------------------
# 3. Create composer.json
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
# 4. Create public/index.php
# ------------------------------------------------------

echo "⚙️ Creating Slim entrypoint..."

cat > public/index.php <<'EOF'
<?php
declare(strict_types=1);

use Slim\Factory\AppFactory;
use Dotenv\Dotenv;

require __DIR__ . '/../vendor/autoload.php';

$dotenv = Dotenv::createImmutable(__DIR__ . '/../');
$dotenv->load();

$container = require __DIR__ . '/../bootstrap/Container.php';
AppFactory::setContainer($container);

$app = AppFactory::create();
(require __DIR__ . '/../app/Routes/routes.php')($app);

$app->run();
EOF

# ------------------------------------------------------
# 5. Create bootstrap files
# ------------------------------------------------------

echo "🧱 Creating bootstrap files..."

cat > bootstrap/Container.php <<'EOF'
<?php
use DI\ContainerBuilder;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;
use App\DataAccess\DatabaseFactory;

$containerBuilder = new ContainerBuilder();

$containerBuilder->addDefinitions([
    Logger::class => function () {
        $logger = new Logger('doob');
        $logger->pushHandler(new StreamHandler(__DIR__ . '/../storage/logs/app.log', Logger::DEBUG));
        return $logger;
    },
    PDO::class => function () {
        $factory = new DatabaseFactory();
        return $factory->createAdapter();
    }
]);

return $containerBuilder->build();
EOF

cat > bootstrap/app.php <<'EOF'
<?php
require_once __DIR__ . '/../vendor/autoload.php';
EOF

cat > bootstrap/database.php <<'EOF'
<?php
// Placeholder for database configuration bootstrapping
EOF

# ------------------------------------------------------
# 6. Create app files
# ------------------------------------------------------

echo "🧩 Creating core app files..."

# Routes
cat > app/Routes/routes.php <<'EOF'
<?php
use Slim\App;
use App\Controllers\AuthController;
use App\Controllers\UserController;

return function (App $app) {
    $app->get('/', function ($request, $response) {
        $data = ['status' => 'ok', 'message' => 'Doob API is running'];
        $response->getBody()->write(json_encode($data));
        return $response->withHeader('Content-Type', 'application/json');
    });

    $app->get('/users', [UserController::class, 'index']);
    $app->post('/auth/login', [AuthController::class, 'login']);
};
EOF

# Response Helper
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

# Controllers
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
# 7. Database Layer
# ------------------------------------------------------

echo "🗄️ Creating Database Adapter Layer..."

cat > app/DataAccess/Contracts/DatabaseAdapterInterface.php <<'EOF'
<?php
namespace App\DataAccess\Contracts;

interface DatabaseAdapterInterface
{
    public function getConnection();
}
EOF

cat > app/DataAccess/Adapters/PostgresAdapter.php <<'EOF'
<?php
namespace App\DataAccess\Adapters;

use App\DataAccess\Contracts\DatabaseAdapterInterface;
use PDO;

class PostgresAdapter implements DatabaseAdapterInterface
{
    public function getConnection()
    {
        $dsn = sprintf(
            'pgsql:host=%s;port=%s;dbname=%s',
            $_ENV['DB_HOST'],
            $_ENV['DB_PORT'],
            $_ENV['DB_DATABASE']
        );
        return new PDO($dsn, $_ENV['DB_USERNAME'], $_ENV['DB_PASSWORD']);
    }
}
EOF

cat > app/DataAccess/Adapters/MysqlAdapter.php <<'EOF'
<?php
namespace App\DataAccess\Adapters;

use App\DataAccess\Contracts\DatabaseAdapterInterface;
use PDO;

class MysqlAdapter implements DatabaseAdapterInterface
{
    public function getConnection()
    {
        $dsn = sprintf(
            'mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
            $_ENV['DB_HOST'],
            $_ENV['DB_PORT'],
            $_ENV['DB_DATABASE']
        );
        return new PDO($dsn, $_ENV['DB_USERNAME'], $_ENV['DB_PASSWORD']);
    }
}
EOF

cat > app/DataAccess/DatabaseFactory.php <<'EOF'
<?php
namespace App\DataAccess;

use App\DataAccess\Adapters\PostgresAdapter;
use App\DataAccess\Adapters\MysqlAdapter;
use App\DataAccess\Contracts\DatabaseAdapterInterface;

class DatabaseFactory
{
    public function createAdapter(): DatabaseAdapterInterface
    {
        $driver = $_ENV['DB_DRIVER'] ?? 'pgsql';

        return match ($driver) {
            'mysql' => new MysqlAdapter(),
            default => new PostgresAdapter(),
        };
    }
}
EOF

# ------------------------------------------------------
# 8. Kernel + Console + Helpers
# ------------------------------------------------------

echo "🧠 Creating Kernel structure..."

cat > Kernel/helpers.php <<'EOF'
<?php
// Global helper functions can be defined here
EOF

cat > bin/console <<'EOF'
#!/usr/bin/env php
<?php
require __DIR__ . '/../vendor/autoload.php';

use Symfony\Component\Console\Application;

$application = new Application('Doob API Console', '1.0.0');

// Future commands will be registered here

$application->run();
EOF

chmod +x bin/console

# ------------------------------------------------------
# 9. Config files
# ------------------------------------------------------

echo "🧩 Adding configs..."

cat > configs/app.php <<'EOF'
<?php
return [
    'name' => $_ENV['APP_NAME'] ?? 'Doob API',
    'env' => $_ENV['APP_ENV'] ?? 'production',
    'debug' => $_ENV['APP_DEBUG'] ?? false,
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
# 10. Final message
# ------------------------------------------------------

echo "✅ Doob API structure created successfully!"
echo ""
echo "Next steps:"
echo "---------------------------------------"
echo "cd doob-api"
echo "composer install"
echo "php -S localhost:8080 -t public"
echo ""
echo "Then open: http://localhost:8080"
echo ""
echo "🎉 Enjoy your new Slim 4 Doob API!"
