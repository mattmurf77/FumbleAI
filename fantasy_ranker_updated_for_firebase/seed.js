const admin = require("firebase-admin");
const fs = require("fs");

// Replace this with the correct path to your Firebase Admin SDK key
const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();
const players = JSON.parse(fs.readFileSync("fantasy_players_seed.json", "utf-8"));

async function seedPlayers() {
  const batch = db.batch();
  for (const player of players) {
    const ref = db.collection("players").doc(player.id);
    batch.set(ref, player);
  }
  await batch.commit();
  console.log("✅ Seeded players into Firestore.");
}

seedPlayers();
