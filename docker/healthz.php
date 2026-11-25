<?php
/**
 * Readiness probe used by Docker, Jenkins tests and the canary script.
 * 200 = app boots and Aiven MySQL answers over TLS; 503 otherwise.
 * Never prints connection details or error messages (they may contain secrets).
 */
require_once __DIR__ . '/app/bootstrap.php';
require_once LEGACY_ROOT . '/app/config/database.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$dbOk = false;
try {
    $conn = smarttunes_db_connect();
    $dbOk = (bool) $conn->query('SELECT 1');
    $conn->close();
} catch (Throwable $error) {
    error_log('healthz: database check failed');
}

http_response_code($dbOk ? 200 : 503);
echo json_encode([
    'status' => $dbOk ? 'ok' : 'error',
    'db' => $dbOk ? 'ok' : 'unreachable',
    'version' => getenv('APP_VERSION') ?: 'unknown',
]);
