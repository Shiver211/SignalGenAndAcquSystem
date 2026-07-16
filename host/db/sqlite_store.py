"""M8 SQLite 单文件存储：元数据、测量结果和整帧 BLOB。"""

from __future__ import annotations

import binascii
import json
import sqlite3
import threading
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from host.comm.data_protocol import CompletedFrame, Measurement, PacketHeader


SCHEMA_VERSION = 1


@dataclass(frozen=True)
class CaptureRecord:
    id: int
    captured_at: str
    frame_id: int
    data_type: int
    sample_format: int
    total_samples: int
    sample_rate_hz: int
    trigger_index: int
    payload_bytes: int
    payload_crc32: int
    note: str


class SqliteStore:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._configure()
        self._create_schema()

    def _configure(self) -> None:
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=NORMAL")
        self._connection.execute("PRAGMA foreign_keys=ON")

    def _create_schema(self) -> None:
        with self._connection:
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS app_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS captures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    captured_at TEXT NOT NULL,
                    frame_id INTEGER NOT NULL,
                    data_type INTEGER NOT NULL,
                    sample_format INTEGER NOT NULL,
                    total_samples INTEGER NOT NULL,
                    sample_rate_hz INTEGER NOT NULL,
                    trigger_index INTEGER NOT NULL,
                    channel_mask INTEGER NOT NULL,
                    flags INTEGER NOT NULL,
                    config_json TEXT NOT NULL,
                    payload_bytes INTEGER NOT NULL,
                    payload_crc32 INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    note TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS idx_captures_time ON captures(captured_at DESC);
                CREATE INDEX IF NOT EXISTS idx_captures_frame ON captures(frame_id, data_type);

                CREATE TABLE IF NOT EXISTS measurements (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    capture_id INTEGER,
                    recorded_at TEXT NOT NULL,
                    frame_id INTEGER NOT NULL,
                    min_a INTEGER NOT NULL,
                    max_a INTEGER NOT NULL,
                    min_b INTEGER NOT NULL,
                    max_b INTEGER NOT NULL,
                    mean_a INTEGER NOT NULL,
                    mean_b INTEGER NOT NULL,
                    vpp_a INTEGER NOT NULL,
                    vpp_b INTEGER NOT NULL,
                    otr_count_a INTEGER NOT NULL,
                    otr_count_b INTEGER NOT NULL,
                    period_samples_a INTEGER NOT NULL,
                    period_samples_b INTEGER NOT NULL,
                    frequency_hz_a INTEGER NOT NULL,
                    frequency_hz_b INTEGER NOT NULL,
                    period_valid_a INTEGER NOT NULL,
                    period_valid_b INTEGER NOT NULL,
                    calculation_overrun INTEGER NOT NULL,
                    FOREIGN KEY(capture_id) REFERENCES captures(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_measurements_time
                    ON measurements(recorded_at DESC);
                """
            )
            self._connection.execute(
                "INSERT OR REPLACE INTO app_meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )

    def save_frame(
        self,
        frame: CompletedFrame,
        *,
        config: dict[str, Any] | None = None,
        note: str = "",
    ) -> int:
        header = frame.header
        captured_at = datetime.now(timezone.utc).isoformat()
        crc = binascii.crc32(frame.payload) & 0xFFFFFFFF
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                INSERT INTO captures(
                    captured_at, frame_id, data_type, sample_format,
                    total_samples, sample_rate_hz, trigger_index,
                    channel_mask, flags, config_json, payload_bytes,
                    payload_crc32, payload, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    captured_at, header.frame_id, header.data_type, header.sample_format,
                    header.total_samples, header.sample_rate_hz, header.trigger_index,
                    header.channel_mask, header.flags,
                    json.dumps(config or {}, ensure_ascii=False, sort_keys=True),
                    len(frame.payload), crc, sqlite3.Binary(frame.payload), note,
                ),
            )
            return int(cursor.lastrowid)

    def save_measurement(
        self,
        frame_id: int,
        measurement: Measurement,
        *,
        capture_id: int | None = None,
    ) -> int:
        values = asdict(measurement)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                INSERT INTO measurements(
                    capture_id, recorded_at, frame_id,
                    min_a, max_a, min_b, max_b, mean_a, mean_b, vpp_a, vpp_b,
                    otr_count_a, otr_count_b, period_samples_a, period_samples_b,
                    frequency_hz_a, frequency_hz_b, period_valid_a, period_valid_b,
                    calculation_overrun
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    capture_id, datetime.now(timezone.utc).isoformat(), frame_id,
                    values["min_a"], values["max_a"], values["min_b"], values["max_b"],
                    values["mean_a"], values["mean_b"], values["vpp_a"], values["vpp_b"],
                    values["otr_count_a"], values["otr_count_b"],
                    values["period_samples_a"], values["period_samples_b"],
                    values["frequency_hz_a"], values["frequency_hz_b"],
                    int(values["period_valid_a"]), int(values["period_valid_b"]),
                    int(values["calculation_overrun"]),
                ),
            )
            return int(cursor.lastrowid)

    def list_captures(self, limit: int = 200) -> list[CaptureRecord]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT id, captured_at, frame_id, data_type, sample_format,
                       total_samples, sample_rate_hz, trigger_index,
                       payload_bytes, payload_crc32, note
                FROM captures ORDER BY id DESC LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [CaptureRecord(**dict(row)) for row in rows]

    def load_frame(self, record_id: int) -> CompletedFrame:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM captures WHERE id = ?", (record_id,)
            ).fetchone()
        if row is None:
            raise KeyError(f"记录 {record_id} 不存在")
        payload = bytes(row["payload"])
        crc = binascii.crc32(payload) & 0xFFFFFFFF
        if crc != row["payload_crc32"]:
            raise ValueError("数据库帧 BLOB CRC32 校验失败")
        header = PacketHeader(
            version=1, data_type=row["data_type"], frame_id=row["frame_id"],
            total_samples=row["total_samples"], sample_rate_hz=row["sample_rate_hz"],
            trigger_index=row["trigger_index"], channel_mask=row["channel_mask"],
            sample_format=row["sample_format"], chunk_index=0, chunk_offset=0,
            payload_len=len(payload), flags=row["flags"],
        )
        return CompletedFrame(header, payload)

    def delete_capture(self, record_id: int) -> None:
        with self._lock, self._connection:
            self._connection.execute("DELETE FROM captures WHERE id = ?", (record_id,))

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def __enter__(self) -> "SqliteStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
