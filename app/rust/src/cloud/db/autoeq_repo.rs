use crate::cloud::db::AutoEqProfileRow;
use rusqlite::{params, Connection, Result, Row};

/// Repository for AutoEQ headphone profiles and app key-value configuration.
pub struct AutoEqRepository<'a> {
    pub conn: &'a Connection,
}

impl<'a> AutoEqRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// Stores a persistent key-value configuration pair.
    pub fn set_kv(&self, key: &str, val: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO app_kv (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, val],
        )?;
        Ok(())
    }

    /// Reads a persistent key-value configuration pair.
    pub fn get_kv(&self, key: &str) -> Result<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT value FROM app_kv WHERE key = ?1")?;
        let mut rows = stmt.query_map(params![key], |r| r.get::<_, String>(0))?;
        match rows.next() {
            Some(res) => res.map(Some),
            None => Ok(None),
        }
    }

    /// Deletes a persistent key-value configuration pair.
    pub fn delete_kv(&self, key: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM app_kv WHERE key = ?1", params![key])?;
        Ok(())
    }

    /// Lists all key-value configuration pairs starting with a given prefix.
    pub fn list_kv_prefix(&self, prefix: &str) -> Result<Vec<(String, String)>> {
        let pattern = format!("{}%", prefix);
        let mut stmt = self
            .conn
            .prepare("SELECT key, value FROM app_kv WHERE key LIKE ?1 ORDER BY key ASC")?;
        let rows = stmt.query_map(params![pattern], |r| Ok((r.get(0)?, r.get(1)?)))?;
        let mut result = Vec::new();
        for r in rows {
            result.push(r?);
        }
        Ok(result)
    }

    #[inline]
    fn row_to_autoeq_profile(r: &Row) -> Result<AutoEqProfileRow> {
        Ok(AutoEqProfileRow {
            id: r.get(0)?,
            model: r.get(1)?,
            brand: r.get(2)?,
            source: r.get(3)?,
            target: r.get(4)?,
            suggested_preamp_db: r.get(5)?,
            bands_json: r.get(6)?,
        })
    }

    /// Searches AutoEQ profiles by model name or brand (case-insensitive substring).
    pub fn search_autoeq_profiles(&self, query: &str) -> Result<Vec<AutoEqProfileRow>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            let mut stmt = self.conn.prepare(
                "SELECT id, model, brand, source, target, suggested_preamp_db, bands_json
                 FROM autoeq_profiles
                 ORDER BY brand ASC, model ASC
                 LIMIT 100",
            )?;
            let rows = stmt.query_map([], Self::row_to_autoeq_profile)?;
            let mut result = Vec::new();
            for r in rows {
                result.push(r?);
            }
            Ok(result)
        } else {
            let pattern = format!("%{}%", trimmed);
            let mut stmt = self.conn.prepare(
                "SELECT id, model, brand, source, target, suggested_preamp_db, bands_json
                 FROM autoeq_profiles
                 WHERE model LIKE ?1 OR brand LIKE ?1
                 ORDER BY brand ASC, model ASC
                 LIMIT 100",
            )?;
            let rows = stmt.query_map(params![pattern], Self::row_to_autoeq_profile)?;
            let mut result = Vec::new();
            for r in rows {
                result.push(r?);
            }
            Ok(result)
        }
    }

    /// Fetches a single AutoEQ profile by its unique ID.
    pub fn get_autoeq_profile(&self, id: &str) -> Result<Option<AutoEqProfileRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, model, brand, source, target, suggested_preamp_db, bands_json
             FROM autoeq_profiles
             WHERE id = ?1",
        )?;
        let mut rows = stmt.query_map(params![id], Self::row_to_autoeq_profile)?;
        match rows.next() {
            Some(res) => res.map(Some),
            None => Ok(None),
        }
    }

    /// Inserts or updates an AutoEQ profile.
    pub fn insert_autoeq_profile(&self, p: &AutoEqProfileRow) -> Result<()> {
        self.conn.execute(
            "INSERT INTO autoeq_profiles (id, model, brand, source, target, suggested_preamp_db, bands_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(id) DO UPDATE SET
                model = excluded.model,
                brand = excluded.brand,
                source = excluded.source,
                target = excluded.target,
                suggested_preamp_db = excluded.suggested_preamp_db,
                bands_json = excluded.bands_json",
            params![
                p.id,
                p.model,
                p.brand,
                p.source,
                p.target,
                p.suggested_preamp_db,
                p.bands_json
            ],
        )?;
        Ok(())
    }

    /// Seeds curated audiophile headphone/IEM profiles if table is empty.
    pub fn seed_autoeq_profiles(&self) -> Result<()> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM autoeq_profiles", [], |r| r.get(0))?;
        if count > 0 {
            return Ok(());
        }

        let profiles = Self::curated_autoeq_profiles();
        let mut stmt = self.conn.prepare(
            "INSERT OR REPLACE INTO autoeq_profiles (id, model, brand, source, target, suggested_preamp_db, bands_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?;
        for p in profiles {
            stmt.execute(params![
                p.id,
                p.model,
                p.brand,
                p.source,
                p.target,
                p.suggested_preamp_db,
                p.bands_json
            ])?;
        }
        Ok(())
    }

    /// 28 curated audiophile headphone & IEM profiles targeting Harman 2018/2019 targets.
    pub fn curated_autoeq_profiles() -> Vec<AutoEqProfileRow> {
        struct CuratedDef {
            id: &'static str,
            model: &'static str,
            brand: &'static str,
            source: &'static str,
            target: &'static str,
            preamp: f64,
            bands: &'static [(&'static str, f64, f64, f64)],
        }

        const HARMAN_OE: &str = "Harman Over-Ear 2018";
        const HARMAN_IE: &str = "Harman In-Ear 2019";
        const ORATORY: &str = "oratory1990";
        const CRINACLE: &str = "Crinacle IEC-711";

        let defs: &[CuratedDef] = &[
            CuratedDef {
                id: "aeq-sennheiser-hd600",
                model: "Sennheiser HD 600",
                brand: "Sennheiser",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.4,
                bands: &[
                    ("lowShelf", 45.0, 4.5, 0.71),
                    ("peak", 180.0, -1.8, 1.40),
                    ("peak", 1200.0, -1.2, 2.00),
                    ("peak", 3200.0, 2.4, 2.20),
                    ("peak", 5600.0, -3.2, 4.00),
                    ("highShelf", 10000.0, 1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sennheiser-hd650",
                model: "Sennheiser HD 650 / HD 6XX",
                brand: "Sennheiser",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.6,
                bands: &[
                    ("lowShelf", 40.0, 5.0, 0.71),
                    ("peak", 200.0, -2.1, 1.20),
                    ("peak", 1250.0, -1.5, 1.80),
                    ("peak", 3400.0, 2.8, 2.50),
                    ("peak", 5800.0, -2.8, 3.50),
                    ("highShelf", 10000.0, 2.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sennheiser-hd800s",
                model: "Sennheiser HD 800 S",
                brand: "Sennheiser",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -5.8,
                bands: &[
                    ("lowShelf", 60.0, 4.8, 0.71),
                    ("peak", 1600.0, 1.8, 1.40),
                    ("peak", 5900.0, -5.2, 4.00),
                    ("peak", 8200.0, -2.5, 3.00),
                    ("highShelf", 10000.0, 1.2, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sennheiser-hd560s",
                model: "Sennheiser HD 560S",
                brand: "Sennheiser",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -5.2,
                bands: &[
                    ("lowShelf", 55.0, 3.5, 0.71),
                    ("peak", 1300.0, -1.5, 2.00),
                    ("peak", 4500.0, -3.0, 3.50),
                    ("peak", 7200.0, 1.8, 2.00),
                    ("highShelf", 10000.0, 1.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-hifiman-sundara",
                model: "Hifiman Sundara",
                brand: "Hifiman",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.5,
                bands: &[
                    ("lowShelf", 75.0, 5.5, 0.71),
                    ("peak", 1850.0, 1.5, 1.80),
                    ("peak", 6000.0, -3.8, 3.50),
                    ("peak", 9200.0, -2.0, 2.50),
                    ("highShelf", 10000.0, 1.2, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-hifiman-ananda",
                model: "Hifiman Ananda",
                brand: "Hifiman",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.0,
                bands: &[
                    ("lowShelf", 70.0, 5.2, 0.71),
                    ("peak", 1600.0, 2.2, 1.50),
                    ("peak", 3200.0, -2.5, 2.00),
                    ("peak", 6200.0, -4.0, 3.80),
                    ("highShelf", 10000.0, 1.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-hifiman-edition-xs",
                model: "Hifiman Edition XS",
                brand: "Hifiman",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.3,
                bands: &[
                    ("lowShelf", 65.0, 5.0, 0.71),
                    ("peak", 1800.0, 2.0, 1.60),
                    ("peak", 3000.0, -2.2, 2.20),
                    ("peak", 6400.0, -3.5, 3.50),
                    ("highShelf", 10000.0, 1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-beyer-dt770-80",
                model: "Beyerdynamic DT 770 Pro 80 Ohm",
                brand: "Beyerdynamic",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -5.9,
                bands: &[
                    ("peak", 120.0, -2.8, 1.20),
                    ("peak", 250.0, -1.5, 1.50),
                    ("peak", 3800.0, 3.2, 2.20),
                    ("peak", 6000.0, -5.5, 4.00),
                    ("highShelf", 10000.0, -2.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-beyer-dt990-250",
                model: "Beyerdynamic DT 990 Pro 250 Ohm",
                brand: "Beyerdynamic",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.2,
                bands: &[
                    ("lowShelf", 85.0, 4.0, 0.71),
                    ("peak", 700.0, 1.8, 1.50),
                    ("peak", 4200.0, 2.5, 2.00),
                    ("peak", 5800.0, -6.8, 4.50),
                    ("peak", 8500.0, -4.2, 3.00),
                ],
            },
            CuratedDef {
                id: "aeq-beyer-dt1990",
                model: "Beyerdynamic DT 1990 Pro",
                brand: "Beyerdynamic",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -7.0,
                bands: &[
                    ("lowShelf", 80.0, 4.2, 0.71),
                    ("peak", 220.0, -1.8, 1.40),
                    ("peak", 4400.0, 2.8, 2.00),
                    ("peak", 7800.0, -6.5, 4.20),
                    ("highShelf", 10000.0, -1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-ath-m50x",
                model: "Audio-Technica ATH-M50x",
                brand: "Audio-Technica",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -5.5,
                bands: &[
                    ("peak", 180.0, -3.5, 1.20),
                    ("peak", 450.0, 1.8, 1.80),
                    ("peak", 3200.0, -2.4, 2.00),
                    ("peak", 9500.0, -4.0, 3.50),
                    ("highShelf", 11000.0, 2.2, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sony-wh1000xm4",
                model: "Sony WH-1000XM4",
                brand: "Sony",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.8,
                bands: &[
                    ("peak", 150.0, -5.5, 1.00),
                    ("peak", 650.0, 2.2, 1.80),
                    ("peak", 1800.0, 3.5, 2.00),
                    ("peak", 6500.0, -2.8, 3.00),
                    ("highShelf", 10000.0, 2.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sony-wh1000xm5",
                model: "Sony WH-1000XM5",
                brand: "Sony",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -6.0,
                bands: &[
                    ("peak", 140.0, -4.8, 1.10),
                    ("peak", 1200.0, 2.5, 1.80),
                    ("peak", 3100.0, 2.0, 2.20),
                    ("peak", 6800.0, -3.2, 3.20),
                    ("highShelf", 10000.0, 1.8, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-apple-airpods-max",
                model: "Apple AirPods Max",
                brand: "Apple",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -4.5,
                bands: &[
                    ("lowShelf", 60.0, 2.5, 0.71),
                    ("peak", 1200.0, -1.8, 2.00),
                    ("peak", 3400.0, 2.2, 2.20),
                    ("peak", 7500.0, -3.0, 3.50),
                    ("highShelf", 10000.0, 1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-apple-airpods-pro-2",
                model: "Apple AirPods Pro 2",
                brand: "Apple",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -4.8,
                bands: &[
                    ("lowShelf", 85.0, 2.8, 0.71),
                    ("peak", 250.0, -1.2, 1.40),
                    ("peak", 2800.0, 2.5, 2.00),
                    ("peak", 6200.0, -2.2, 3.00),
                    ("highShelf", 10000.0, 1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-moondrop-blessing2",
                model: "Moondrop Blessing 2",
                brand: "Moondrop",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.8,
                bands: &[
                    ("lowShelf", 105.0, 4.8, 0.71),
                    ("peak", 220.0, -1.5, 1.20),
                    ("peak", 3200.0, -2.0, 2.50),
                    ("peak", 6000.0, 2.5, 3.00),
                    ("highShelf", 10500.0, -1.8, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-moondrop-blessing2-dusk",
                model: "Moondrop Blessing 2 Dusk",
                brand: "Moondrop",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -4.2,
                bands: &[
                    ("lowShelf", 80.0, 2.0, 0.71),
                    ("peak", 2500.0, -1.8, 2.20),
                    ("peak", 6200.0, 2.0, 3.00),
                    ("highShelf", 10000.0, -1.2, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-moondrop-aria",
                model: "Moondrop Aria",
                brand: "Moondrop",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.0,
                bands: &[
                    ("lowShelf", 90.0, 3.2, 0.71),
                    ("peak", 3000.0, -2.2, 2.00),
                    ("peak", 6500.0, 2.8, 3.20),
                    ("highShelf", 10000.0, -1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-moondrop-kato",
                model: "Moondrop Kato",
                brand: "Moondrop",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -4.5,
                bands: &[
                    ("lowShelf", 85.0, 2.5, 0.71),
                    ("peak", 2800.0, -1.8, 2.00),
                    ("peak", 6000.0, 2.2, 2.80),
                    ("highShelf", 10000.0, -1.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-moondrop-chu",
                model: "Moondrop Chu",
                brand: "Moondrop",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.5,
                bands: &[
                    ("lowShelf", 100.0, 4.5, 0.71),
                    ("peak", 3200.0, -2.8, 2.20),
                    ("peak", 6500.0, -3.5, 3.50),
                    ("highShelf", 10000.0, 1.8, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-titanx",
                model: "DUNU Titan X",
                brand: "DUNU",
                source: ORATORY,
                target: HARMAN_IE,
                preamp: -6.2,
                bands: &[
                    ("lowShelf", 105.0, 3.4, 0.70),
                    ("peak", 212.0, -1.8, 1.10),
                    ("peak", 1150.0, 1.2, 1.40),
                    ("peak", 2900.0, -2.6, 2.20),
                    ("peak", 5200.0, 2.1, 2.80),
                    ("peak", 7800.0, -3.2, 3.40),
                    ("highShelf", 10500.0, 1.6, 0.70),
                ],
            },
            CuratedDef {
                id: "aeq-dunu-titan-s",
                model: "DUNU Titan S",
                brand: "DUNU",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.0,
                bands: &[
                    ("lowShelf", 95.0, 3.8, 0.71),
                    ("peak", 2800.0, -2.0, 2.00),
                    ("peak", 5800.0, 2.2, 2.80),
                    ("highShelf", 10000.0, -1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-truthear-zero-red",
                model: "Truthear ZERO:RED",
                brand: "Truthear",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -4.0,
                bands: &[
                    ("lowShelf", 70.0, 2.0, 0.71),
                    ("peak", 3000.0, -1.5, 2.00),
                    ("peak", 6000.0, 2.5, 3.00),
                    ("highShelf", 10000.0, -1.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-truthear-hexa",
                model: "Truthear Hexa",
                brand: "Truthear",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -4.8,
                bands: &[
                    ("lowShelf", 85.0, 3.2, 0.71),
                    ("peak", 2800.0, -1.8, 2.20),
                    ("peak", 6200.0, 2.0, 3.00),
                    ("highShelf", 10000.0, -1.2, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-7hz-timeless",
                model: "7Hz Timeless",
                brand: "7Hz",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.5,
                bands: &[
                    ("lowShelf", 90.0, 2.5, 0.71),
                    ("peak", 2200.0, 2.2, 1.80),
                    ("peak", 5800.0, -3.5, 3.20),
                    ("peak", 8000.0, -4.5, 3.50),
                    ("highShelf", 10000.0, 1.5, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-tangzu-waner",
                model: "Tangzu Wan'er",
                brand: "Tangzu",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.2,
                bands: &[
                    ("lowShelf", 100.0, 3.5, 0.71),
                    ("peak", 2900.0, -2.4, 2.00),
                    ("peak", 6200.0, -2.8, 3.20),
                    ("highShelf", 10000.0, 1.8, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-sony-ier-m9",
                model: "Sony IER-M9",
                brand: "Sony",
                source: CRINACLE,
                target: HARMAN_IE,
                preamp: -5.0,
                bands: &[
                    ("lowShelf", 80.0, 2.8, 0.71),
                    ("peak", 2500.0, 2.0, 2.00),
                    ("peak", 6000.0, -2.5, 3.00),
                    ("highShelf", 10000.0, 2.0, 0.71),
                ],
            },
            CuratedDef {
                id: "aeq-akg-k371",
                model: "AKG K371",
                brand: "AKG",
                source: ORATORY,
                target: HARMAN_OE,
                preamp: -4.0,
                bands: &[
                    ("lowShelf", 60.0, 2.0, 0.71),
                    ("peak", 220.0, -1.8, 1.50),
                    ("peak", 3800.0, 2.0, 2.50),
                    ("peak", 6500.0, -2.5, 3.00),
                    ("highShelf", 10000.0, 1.2, 0.71),
                ],
            },
        ];

        defs.iter()
            .map(|d| {
                let bands_str = d
                    .bands
                    .iter()
                    .enumerate()
                    .map(|(idx, &(b_type, freq, gain, q))| {
                        format!(
                            r#"{{"id":{},"type":"{}","frequencyHz":{:.1},"gainDb":{:.1},"q":{:.2},"enabled":true}}"#,
                            idx + 1,
                            b_type,
                            freq,
                            gain,
                            q
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",");
                AutoEqProfileRow {
                    id: d.id.to_string(),
                    model: d.model.to_string(),
                    brand: d.brand.to_string(),
                    source: d.source.to_string(),
                    target: d.target.to_string(),
                    suggested_preamp_db: d.preamp,
                    bands_json: format!("[{}]", bands_str),
                }
            })
            .collect()
    }
}
