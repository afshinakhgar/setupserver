#!/bin/bash
set -e

PROJECT_NAME=${1:-"doob-api"}

echo "🚀 Setting up project: $PROJECT_NAME ..."

# Create base directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Folder structure
mkdir -p public app/{Controllers,Routes,Helpers,DataAccess/{Contracts,Adapters,Repositories}} \
         Kernel/{Console/Commands} bootstrap config storage/logs bin vendor

# ----------------------------------------------------------------
# .env
# ----------------------------------------------------------------
cat > .env <<EOF
APP_ENV=local
APP_DEBUG=true
APP_NAME="$PROJECT_NAME"
DB_DRIVER=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=${PROJECT_NAME}_db
DB_USERNAME=root
DB_PASSWORD=root
ELASTIC_PASSWORD=changeme
EOF

# ----------------------------------------------------------------
# composer.json
# ----------------------------------------------------------------
cat > composer.json <<'EOF'
{
  "require": {
    "php": "^8.1",
    "ext-pdo": "*",
    "slim/slim": "^4.13",
    "slim/psr7": "^1.6",
    "vlucas/phpdotenv": "^5.6",
    "php-di/php-di": "^7.0",
    "monolog/monolog": "^3",
    "symfony/console": "^7.1",
    "respect/validation": "^2.2",
    "elasticsearch/elasticsearch": "^8.19",
    "guzzlehttp/guzzle": "^7"
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
  },
  "config": {
    "allow-plugins": {
      "php-http/discovery": true
    }
  }
}
EOF

# ----------------------------------------------------------------
# bootstrap/container.php
# ----------------------------------------------------------------
cat > bootstrap/container.php <<'EOF'
<?php
use DI\ContainerBuilder;
use Elastic\Elasticsearch\ClientBuilder;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;

$containerBuilder = new ContainerBuilder();
$root = dirname(__DIR__);

class KibanaFormatter extends \Monolog\Formatter\ElasticsearchFormatter {
    public function __construct(string $index, string $type) {
        parent::__construct($index, $type);
        $this->setDateFormat('c');
    }

    public function format(array|\Monolog\LogRecord $record): array {
        $doc = parent::format($record);
        if (isset($doc['datetime'])) {
            $doc['@timestamp'] = $doc['datetime'];
            unset($doc['datetime']);
        }
        return $doc;
    }
}

$containerBuilder->addDefinitions([
    'config.app' => fn() => require $root.'/config/app.php',
    'config.db'  => fn() => require $root.'/config/database.php',

    'elastic.client' => function () {
        return ClientBuilder::create()
            ->setHosts(['https://log.dotroot.ir/ingest'])
            ->setBasicAuthentication('elastic', env('ELASTIC_PASSWORD'))
            ->setElasticMetaHeader(false)
            ->setSSLVerification(true)
            ->build();
    },

    'elasticsearch.handler' => function ($c) {
        $client = $c->get('elastic.client');
        $handler = new \Monolog\Handler\ElasticsearchHandler(
            $client,
            ['index' => 'nginx-realaffiliate'],
            Logger::DEBUG,
            true
        );
        $handler->setFormatter(new KibanaFormatter('nginx-realaffiliate', '_doc'));
        return $handler;
    },

    \Psr\Log\LoggerInterface::class => function ($c) use ($root) {
        $cfg  = $c->get('config.app');
        $path = $cfg['log_path'] ?? ($root.'/storage/logs/app.log');
        if (!is_dir(dirname($path))) mkdir(dirname($path), 0755, true);

        $logger = new Logger($cfg['log_channel'] ?? 'app');
        $logger->pushHandler(new StreamHandler($path, Logger::DEBUG));
        $logger->pushHandler($c->get('elasticsearch.handler'));
        return $logger;
    },

    \PDO::class => function ($c) {
        $cfg = $c->get('config.db');
        $dsn = sprintf(
            'mysql:host=%s;port=%s;dbname=%s;charset=%s',
            $cfg['host'] ?? '127.0.0.1',
            $cfg['port'] ?? '3306',
            $cfg['database'] ?? 'app',
            $cfg['charset'] ?? 'utf8mb4'
        );
        return new \PDO($dsn, $cfg['username'] ?? 'root', $cfg['password'] ?? '', [
            \PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION,
            \PDO::ATTR_DEFAULT_FETCH_MODE => \PDO::FETCH_ASSOC,
            \PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    },
]);

return $containerBuilder->build();
EOF

# ----------------------------------------------------------------
# bootstrap/app.php
# ----------------------------------------------------------------
cat > bootstrap/app.php <<'EOF'
<?php
declare(strict_types=1);

use Slim\Factory\AppFactory;
use Dotenv\Dotenv;

require_once __DIR__ . '/../vendor/autoload.php';

$root = dirname(__DIR__);

if (file_exists($root.'/.env')) {
    Dotenv::createImmutable($root)->load();
}

$container = require __DIR__ . '/container.php';
AppFactory::setContainer($container);

$app = AppFactory::create();
$app->addRoutingMiddleware();
$app->addBodyParsingMiddleware();

$displayErrorDetails = $container->get('config.app')['debug'] ?? false;
$app->addErrorMiddleware(boolval($displayErrorDetails), true, true);

$app->get('/health', function ($request, $response) {
    $response->getBody()->write(json_encode(['status' => 'ok']));
    return $response->withHeader('Content-Type', 'application/json');
});

(require __DIR__ . '/../app/Routes/routes.php')($app);

return $app;
EOF

# ----------------------------------------------------------------
# Kernel Console
# ----------------------------------------------------------------
mkdir -p Kernel/Console/Commands

cat > Kernel/Console/Commands/RouteListCommand.php <<'EOF'
<?php
namespace Kernel\Console\Commands;

use Slim\App;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Helper\Table;

#[AsCommand(name: 'route:list', description: 'List all registered routes')]
class RouteListCommand extends Command
{
    public function __construct(private App $app)
    {
        parent::__construct();
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $routes = $this->app->getRouteCollector()->getRoutes();
        $table = new Table($output);
        $table->setHeaders(['METHODS', 'PATTERN', 'NAME', 'CALLABLE']);

        foreach ($routes as $r) {
            $methods = implode('|', $r->getMethods());
            $pattern = $r->getPattern();
            $name = $r->getName() ?? '';
            $cb = $r->getCallable();

            if (is_string($cb)) $cbStr = $cb;
            elseif (is_array($cb)) {
                $cls = is_object($cb[0]) ? get_class($cb[0]) : (string)$cb[0];
                $cbStr = $cls . '@' . ($cb[1] ?? '');
            } elseif ($cb instanceof \Closure) $cbStr = 'Closure';
            else $cbStr = is_object($cb) ? get_class($cb) : gettype($cb);

            $table->addRow([$methods, $pattern, $name, $cbStr]);
        }

        $table->render();
        return Command::SUCCESS;
    }
}
EOF

cat > Kernel/Console/Kernel.php <<'EOF'
<?php
namespace Kernel\Console;

use Symfony\Component\Console\Application;
use Slim\App;
use Psr\Container\ContainerInterface;
use Kernel\Console\Commands\RouteListCommand;

class Kernel
{
    public function __construct(
        private Application $cli,
        private App $app,
        private ContainerInterface $container
    ) {}

    public function register(): void
    {
        $this->cli->add(new RouteListCommand($this->app));
    }
}
EOF

# ----------------------------------------------------------------
# bin/console
# ----------------------------------------------------------------
cat > bin/console <<'EOF'
#!/usr/bin/env php
<?php
declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use Symfony\Component\Console\Application;
use Kernel\Console\Kernel;

$app = require __DIR__ . '/../bootstrap/app.php';
$container = $app->getContainer();

$application = new Application('Doob API CLI', '1.0.0');

$kernel = new Kernel($application, $app, $container);
$kernel->register();

$application->run();
EOF
chmod +x bin/console

# ----------------------------------------------------------------
# Done
# ----------------------------------------------------------------
echo "✅ Project $PROJECT_NAME created successfully."
echo "Run the following next:"
echo "cd $PROJECT_NAME && composer install"
echo "php -S localhost:8080 -t public"
echo "bin/console route:list"
