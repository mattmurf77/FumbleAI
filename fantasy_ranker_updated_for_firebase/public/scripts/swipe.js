import { auth, db } from "./firebase-auth.js";
import { doc, setDoc, collection, getDocs } from "https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js";

let players = [];
let index = 0;

async function loadPlayers() {
  const snapshot = await getDocs(collection(db, "players"));
  players = snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));
  index = 0;
  renderPlayer();
}

function renderPlayer() {
  if (players.length === 0) {
    document.getElementById("player-card").innerHTML = "No player data found.";
    return;
  }

  const p = players[index];
  document.getElementById("player-name").textContent = `${p.name} (${p.position})`;
  document.getElementById("player-details").innerHTML = `
    Team: ${p.team}<br>
    ADP: ${p.adp}<br>
    Last Year Overall: ${p.lastYearOverall}<br>
    Last Year Position: ${p.lastYearPosition}
  `;
}

async function saveSwipe(userId, playerId, direction) {
  const ref = doc(db, "user_swipes", `${userId}_${playerId}`);
  await setDoc(ref, {
    user_id: userId,
    player_id: playerId,
    direction,
    timestamp: new Date().toISOString()
  });
}

window.swipe = async function(direction) {
  const player = players[index];
  const user = auth.currentUser;

  if (user && player) {
    await saveSwipe(user.uid, player.id, direction);
  }

  index++;
  if (index < players.length) {
    renderPlayer();
  } else {
    document.getElementById("player-card").innerHTML = "<strong>You're done ranking!</strong>";
  }
};

loadPlayers();
