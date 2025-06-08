
const admin = require("firebase-admin");
const fs = require("fs");

admin.initializeApp();
const db = admin.firestore();

async function seedPlayers() {
  const filePath = "./players.json";
  const data = JSON.parse(fs.readFileSync(filePath, "utf8"));

  const minElo = 1000;
  const maxElo = 2000;

  const players = data.players;
  const validPlayers = players.filter(p => p.adp && !isNaN(p.adp));

  const maxADP = Math.max(...validPlayers.map(p => p.adp));
  const minADP = Math.min(...validPlayers.map(p => p.adp));

  const batch = db.batch();

  for (const player of players) {
    const elo = player.adp
      ? Math.round(maxElo - ((player.adp - minADP) / (maxADP - minADP)) * (maxElo - minElo))
      : 1200; // fallback default if no ADP

    const ref = db.collection("players").doc(player.id);
    batch.set(ref, {
      ...player,
      elo: elo
    }, { merge: true });
  }

  await batch.commit();
  console.log("Players seeded with ELO ratings based on ADP.");
}

seedPlayers();
