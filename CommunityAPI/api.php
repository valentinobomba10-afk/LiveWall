<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }

require __DIR__ . '/config.php';

function reply(array $body, int $status = 200): never {
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}
function db(): PDO {
    static $pdo;
    if (!$pdo) {
        $pdo = new PDO('mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4', DB_USER, DB_PASSWORD,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
    }
    return $pdo;
}
function input(): array {
    $data = json_decode(file_get_contents('php://input'), true);
    return is_array($data) ? $data : [];
}
function string(array $data, string $key, int $max): string {
    $value = trim((string)($data[$key] ?? ''));
    return mb_substr($value, 0, $max);
}
function tokenFor(int $userID): string {
    $token = bin2hex(random_bytes(32));
    db()->prepare('INSERT INTO access_tokens (user_id, token_hash, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 30 DAY))')
        ->execute([$userID, hash('sha256', $token)]);
    return $token;
}
function authenticatedUser(): array {
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (!preg_match('/^Bearer ([a-f0-9]{64})$/i', $header, $matches)) reply(['error' => 'Sign in required.'], 401);
    $stmt = db()->prepare('SELECT u.id, u.username FROM access_tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=? AND t.expires_at > NOW() LIMIT 1');
    $stmt->execute([hash('sha256', $matches[1])]);
    $user = $stmt->fetch();
    if (!$user) reply(['error' => 'Your sign-in expired.'], 401);
    return $user;
}
function optionalUserID(): ?int {
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (!preg_match('/^Bearer ([a-f0-9]{64})$/i', $header, $matches)) return null;
    $stmt = db()->prepare('SELECT user_id FROM access_tokens WHERE token_hash=? AND expires_at > NOW() LIMIT 1');
    $stmt->execute([hash('sha256', $matches[1])]); $row = $stmt->fetch();
    return $row ? (int)$row['user_id'] : null;
}
function publicURL(string $filename): string { return rtrim(API_BASE_URL, '/') . '/media/videos/' . rawurlencode($filename); }

$action = $_GET['action'] ?? '';
if ($action === 'update' && $_SERVER['REQUEST_METHOD'] === 'GET') {
    reply(['version' => LATEST_VERSION, 'downloadURL' => UPDATE_DOWNLOAD_URL, 'releaseURL' => UPDATE_RELEASE_URL]);
}
try {
    if ($action === 'register' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $data = input(); $username = string($data, 'username', 32); $email = string($data, 'email', 254); $password = (string)($data['password'] ?? '');
        if (!preg_match('/^[A-Za-z0-9_]{3,32}$/', $username) || !filter_var($email, FILTER_VALIDATE_EMAIL) || strlen($password) < 10)
            reply(['error' => 'Use a 3–32 character username, valid email, and a password with 10+ characters.'], 422);
        $stmt = db()->prepare('INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)');
        $stmt->execute([$username, $email, password_hash($password, PASSWORD_DEFAULT)]);
        $id = (int)db()->lastInsertId(); reply(['token' => tokenFor($id), 'username' => $username], 201);
    }
    if ($action === 'login' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $data = input(); $identity = string($data, 'identity', 254); $password = (string)($data['password'] ?? '');
        $stmt = db()->prepare('SELECT id, username, password_hash FROM users WHERE email=? OR username=? LIMIT 1'); $stmt->execute([$identity, $identity]); $user = $stmt->fetch();
        if (!$user || !password_verify($password, $user['password_hash'])) reply(['error' => 'Incorrect sign-in details.'], 401);
        reply(['token' => tokenFor((int)$user['id']), 'username' => $user['username']]);
    }
    if ($action === 'wallpapers' && $_SERVER['REQUEST_METHOD'] === 'GET') {
        $page = max(1, min(10000, (int)($_GET['page'] ?? 1))); $limit = max(1, min(50, (int)($_GET['limit'] ?? 30))); $offset = ($page - 1) * $limit;
        $stmt = db()->prepare('SELECT w.id, w.title, w.category, w.video_filename, w.byte_size, w.created_at, u.username, w.user_id, (SELECT COUNT(*) FROM wallpaper_events e WHERE e.wallpaper_id=w.id AND e.event_type="download") downloads, (SELECT COUNT(*) FROM wallpaper_events e WHERE e.wallpaper_id=w.id AND e.event_type="apply") applies FROM wallpapers w JOIN users u ON u.id=w.user_id WHERE w.status="approved" ORDER BY w.created_at DESC LIMIT ? OFFSET ?');
        $stmt->bindValue(1, $limit, PDO::PARAM_INT); $stmt->bindValue(2, $offset, PDO::PARAM_INT); $stmt->execute();
        $items = array_map(fn($w) => ['id'=>(int)$w['id'], 'title'=>$w['title'], 'category'=>$w['category'], 'videoURL'=>publicURL($w['video_filename']), 'author'=>$w['username'], 'creatorID'=>(int)$w['user_id'], 'downloads'=>(int)$w['downloads'], 'applies'=>(int)$w['applies'], 'byteSize'=>(int)$w['byte_size'], 'createdAt'=>$w['created_at']], $stmt->fetchAll());
        reply(['wallpapers' => $items]);
    }
    if ($action === 'follow' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $user = authenticatedUser(); $data = input(); $creatorID = (int)($data['creatorID'] ?? 0);
        if ($creatorID < 1 || $creatorID === (int)$user['id']) reply(['error' => 'Choose another creator to follow.'], 422);
        db()->prepare('INSERT IGNORE INTO follows (follower_id, creator_id) VALUES (?, ?)')->execute([$user['id'], $creatorID]);
        reply(['message' => 'Creator followed. You will be notified when an upload is approved.']);
    }
    if ($action === 'report' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $user = authenticatedUser(); $data = input(); $wallpaperID = (int)($data['wallpaperID'] ?? 0); $reason = string($data, 'reason', 80); $details = string($data, 'details', 500);
        if ($wallpaperID < 1 || $reason === '') reply(['error' => 'Select a report reason.'], 422);
        db()->prepare('INSERT IGNORE INTO reports (wallpaper_id, reporter_id, reason, details) VALUES (?, ?, ?, ?)')->execute([$wallpaperID, $user['id'], $reason, $details]);
        reply(['message' => 'Thanks. Your report was sent to the moderation queue.'], 201);
    }
    if ($action === 'track' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $data = input(); $wallpaperID = (int)($data['wallpaperID'] ?? 0); $event = ($data['event'] ?? '') === 'download' ? 'download' : 'apply';
        if ($wallpaperID > 0) db()->prepare('INSERT INTO wallpaper_events (wallpaper_id, user_id, event_type) VALUES (?, ?, ?)')->execute([$wallpaperID, optionalUserID(), $event]);
        reply(['message' => 'Recorded.'], 201);
    }
    if ($action === 'notifications' && $_SERVER['REQUEST_METHOD'] === 'GET') {
        $user = authenticatedUser(); $stmt = db()->prepare('SELECT id, type, title, body, wallpaper_id, read_at, created_at FROM notifications WHERE user_id=? ORDER BY created_at DESC LIMIT 50');
        $stmt->execute([$user['id']]); reply(['notifications' => $stmt->fetchAll()]);
    }
    if ($action === 'read_notifications' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $user = authenticatedUser(); db()->prepare('UPDATE notifications SET read_at=NOW() WHERE user_id=? AND read_at IS NULL')->execute([$user['id']]);
        reply(['message' => 'Notifications marked read.']);
    }
    if ($action === 'upload' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        $user = authenticatedUser();
        if (!isset($_FILES['video']) || $_FILES['video']['error'] !== UPLOAD_ERR_OK) reply(['error' => 'Video upload failed.'], 422);
        $file = $_FILES['video']; if ($file['size'] < 1 || $file['size'] > MAX_VIDEO_BYTES) reply(['error' => 'Video must be under 500 MB.'], 422);
        $mime = (new finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']);
        $types = ['video/mp4'=>'mp4', 'video/quicktime'=>'mov', 'video/webm'=>'webm'];
        if (!isset($types[$mime])) reply(['error' => 'Only MP4, MOV, and WebM videos are accepted.'], 422);
        $title = string($_POST, 'title', 120); $category = string($_POST, 'category', 40);
        if ($title === '') reply(['error' => 'Give your wallpaper a title.'], 422);
        $filename = bin2hex(random_bytes(20)) . '.' . $types[$mime]; $folder = __DIR__ . '/media/videos';
        if (!is_dir($folder) && !mkdir($folder, 0755, true)) reply(['error' => 'Server storage is unavailable.'], 500);
        if (!move_uploaded_file($file['tmp_name'], $folder . '/' . $filename)) reply(['error' => 'Could not save the video.'], 500);
        db()->prepare('INSERT INTO wallpapers (user_id, title, category, video_filename, mime_type, byte_size) VALUES (?, ?, ?, ?, ?, ?)')
            ->execute([$user['id'], $title, $category ?: 'Other', $filename, $mime, $file['size']]);
        reply(['message' => 'Uploaded for review. It will appear in Community after approval.'], 201);
    }
    reply(['error' => 'Unknown endpoint.'], 404);
} catch (PDOException $e) {
    error_log('[LiveWall API] ' . $e->getMessage()); reply(['error' => 'Database temporarily unavailable.'], 503);
}
