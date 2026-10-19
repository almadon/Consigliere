# data_disk

Formats (only if blank) and mounts one dedicated data disk at `data_disk_mount` (default `/srv/bulk`). The `garage` and `loki_server`
roles include it first, so their bulk data (`/srv/bulk/garage`, `/srv/bulk/loki`) lands on that disk and not on the root disk.
Set `data_disk_device` (a `/dev/disk/by-id/...` path) in `config/vars/host/<host>.yml`. Nothing is touched while it is empty. A disk
that already holds a filesystem is never reformatted: the run fails instead. The mount uses `nofail`, so a missing disk cannot block boot.
