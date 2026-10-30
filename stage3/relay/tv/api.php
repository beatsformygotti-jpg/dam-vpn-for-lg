<?php
// D.A.M VPN for LG: почтовый ящик на 10 минут для подписки «телефон → телевизор».
// Хранит только шифр: ключ живёт в QR-коде (после «#» в адресе) и на сервер не попадает.
// POST ?s=СЕССИЯ  {iv, ct} — телефон кладёт шифр; GET ?s=СЕССИЯ — телевизор забирает его один раз.

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');
header('Cache-Control: no-store');

function reply($code, $data) {
    http_response_code($code);
    echo json_encode($data);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    reply(204, null);
}

$dir = __DIR__ . '/data';
if (!is_dir($dir)) {
    mkdir($dir, 0700);
}
foreach (glob($dir . '/*.json') ?: [] as $old) {
    if (filemtime($old) < time() - 600) {
        @unlink($old);
    }
}

$s = isset($_GET['s']) ? $_GET['s'] : '';
if (!preg_match('/^[A-Za-z0-9_-]{22,64}$/', $s)) {
    reply(400, ['error' => 'bad session']);
}
$file = $dir . '/' . hash('sha256', $s) . '.json';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $body = file_get_contents('php://input', false, null, 0, 1048577);
    if ($body === false || strlen($body) > 1048576) {
        reply(413, ['error' => 'too large']);
    }
    $j = json_decode($body, true);
    if (!is_array($j) || !isset($j['iv'], $j['ct'])
        || !preg_match('/^[A-Za-z0-9_-]{16}$/', $j['iv'])
        || !preg_match('/^[A-Za-z0-9_-]{24,1400000}$/', $j['ct'])) {
        reply(400, ['error' => 'bad payload']);
    }
    if (file_exists($file)) {
        reply(409, ['error' => 'already sent']);
    }
    file_put_contents($file, json_encode(['iv' => $j['iv'], 'ct' => $j['ct']]), LOCK_EX);
    reply(200, ['ok' => true]);
}

if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    if (!file_exists($file)) {
        reply(200, ['wait' => true]);
    }
    $data = file_get_contents($file);
    @unlink($file);
    http_response_code(200);
    echo $data;
    exit;
}

reply(405, ['error' => 'method']);
