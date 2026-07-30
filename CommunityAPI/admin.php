<?php
declare(strict_types=1);
require __DIR__ . '/config.php';
if (!hash_equals(ADMIN_TOKEN, (string)($_GET['token'] ?? ''))) { http_response_code(403); exit('Forbidden'); }
$pdo = new PDO('mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4', DB_USER, DB_PASSWORD, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$action = $_POST['action'] ?? ''; $id = (int)($_POST['id'] ?? 0);
if ($id && $action === 'approve') {
  $pdo->prepare("UPDATE wallpapers SET status='approved', approved_at=NOW() WHERE id=?")->execute([$id]);
  $stmt = $pdo->prepare('SELECT w.title, w.user_id FROM wallpapers w WHERE w.id=?'); $stmt->execute([$id]); $wallpaper = $stmt->fetch(PDO::FETCH_ASSOC);
  if ($wallpaper) $pdo->prepare("INSERT INTO notifications (user_id, type, title, body, wallpaper_id) SELECT follower_id, 'creator_upload', ?, ?, ? FROM follows WHERE creator_id=?")
    ->execute(['New wallpaper from a creator you follow', $wallpaper['title'] . ' is now available.', $id, $wallpaper['user_id']]);
}
if ($id && $action === 'reject') $pdo->prepare("UPDATE wallpapers SET status='rejected' WHERE id=?")->execute([$id]);
if ($id && $action === 'review_report') $pdo->prepare("UPDATE reports SET status='reviewed' WHERE id=?")->execute([$id]);
$pending = $pdo->query("SELECT w.id,w.title,u.username,w.created_at FROM wallpapers w JOIN users u ON u.id=w.user_id WHERE w.status='pending' ORDER BY w.created_at ASC")->fetchAll(PDO::FETCH_ASSOC);
$reports = $pdo->query("SELECT r.id,r.reason,r.details,w.title,u.username,r.created_at FROM reports r JOIN wallpapers w ON w.id=r.wallpaper_id JOIN users u ON u.id=r.reporter_id WHERE r.status='new' ORDER BY r.created_at ASC")->fetchAll(PDO::FETCH_ASSOC);
?><!doctype html><meta charset="utf-8"><title>LiveWall moderation</title><style>body{font:16px -apple-system;margin:40px;background:#101015;color:#eee}section{background:#1c1c25;padding:20px;border-radius:12px;margin:20px 0}button{padding:8px 12px;margin-left:8px}small{color:#aaa}</style><h1>LiveWall moderation</h1>
<section><h2>Pending uploads</h2><?php foreach($pending as $w): ?><p><b><?=htmlspecialchars($w['title'])?></b> by <?=htmlspecialchars($w['username'])?> <small><?=htmlspecialchars($w['created_at'])?></small><form method="post" style="display:inline"><input type="hidden" name="id" value="<?=$w['id']?>"><button name="action" value="approve">Approve</button><button name="action" value="reject">Reject</button></form></p><?php endforeach; if(!$pending) echo '<p>Nothing pending.</p>'; ?></section>
<section><h2>New reports</h2><?php foreach($reports as $r): ?><p><b><?=htmlspecialchars($r['title'])?></b> — <?=htmlspecialchars($r['reason'])?> by <?=htmlspecialchars($r['username'])?><br><small><?=htmlspecialchars($r['details'])?></small><form method="post" style="display:inline"><input type="hidden" name="id" value="<?=$r['id']?>"><button name="action" value="review_report">Mark reviewed</button></form></p><?php endforeach; if(!$reports) echo '<p>No new reports.</p>'; ?></section>
