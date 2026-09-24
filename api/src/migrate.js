// Aplica, em ordem, os arquivos de migrations/ ainda não registrados.
// Executado como task única no deploy, nunca pelas réplicas da API.
const fs = require('fs');
const path = require('path');
const pool = require('./db');

const DIR = path.join(__dirname, '..', 'migrations');

async function main() {
  const client = await pool.connect();
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`);
    const { rows } = await client.query('SELECT name FROM schema_migrations');
    const applied = new Set(rows.map((r) => r.name));
    const files = fs
      .readdirSync(DIR)
      .filter((f) => f.endsWith('.sql'))
      .sort();

    for (const file of files) {
      if (applied.has(file)) continue;
      console.log(`Aplicando ${file}`);
      await client.query('BEGIN');
      try {
        await client.query(fs.readFileSync(path.join(DIR, file), 'utf8'));
        await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK');
        throw err;
      }
    }
    console.log('Migrations concluídas');
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch((err) => {
  console.error('Falha na migration:', err);
  process.exit(1);
});
