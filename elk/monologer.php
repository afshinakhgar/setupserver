<?php

//composer require monolog/monolog:^3 elasticsearch/elasticsearch:^8 guzzlehttp/guzzle:^7


?>  


<?php
require __DIR__ . '/vendor/autoload.php';

use Monolog\Logger;
use Monolog\Handler\ElasticsearchHandler;
use Monolog\Formatter\ElasticsearchFormatter;
use Elastic\Elasticsearch\ClientBuilder;

// تنظیم کلاینت (به Nginx /ingest روی دامنه)
$client = ClientBuilder::create()
    ->setHosts(['https://log.dotroot.ir'])  // فقط دامنه
    ->setBasicAuthentication('elastic', 'ELASTIC_PASSWORD_HERE')
    ->setElasticMetaHeader(false)
    ->setSSLVerification(true)              // گواهی عمومی است
    ->setHttpClient(\Elastic\Elasticsearch\HttpClient\Transport::create(
        null,
        ['headers' => ['Host' => 'log.dotroot.ir'], 'base_uri' => 'https://log.dotroot.ir/ingest']  // مسیر پروکسی
    ))
    ->build();

// هندلر به الیاس "nginx-realaffiliate"
$handler = new ElasticsearchHandler($client, [
    'index' => 'nginx-realaffiliate',
    'type'  => '_doc'
], ['ignore_error' => true]);

// فرمت ECS با فیلد @timestamp
$handler->setFormatter(new ElasticsearchFormatter('nginx-realaffiliate', '_doc'));

$log = new Logger('app');
$log->pushHandler($handler);

// افزودن فیلد پروژه
$log->pushProcessor(function ($record) {
    $record['extra']['project'] = ['site' => 'realaffiliate.com'];
    return $record;
});

// تست
$log->info('Hello from Monolog!', ['path' => '/test', 'user_id' => 123]);
