
import { db, auth } from './firebase-auth.js';
import {
  doc, setDoc, collection, addDoc, getDocs
} from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

async function fetchInternalPlayers() {
  const snapshot = await getDocs(collection(db, 'players'));
  const playerMap = {};
  snapshot.forEach(doc => {
    const player = doc.data();
    playerMap[player.sleeper_id] = { id: doc.id, ...player };
  });
  return playerMap;
}

document.getElementById("sleeper-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const leagueId = document.getElementById("leagueId").value;
  const output = document.getElementById("output");
  const user = auth.currentUser;
  if (!user) {
    output.innerHTML = "<div class='alert alert-warning'>Please sign in first.</div>";
    return;
  }

  try {
    output.innerHTML = "⏳ Importing league...";
    const leagueRes = await fetch(`https://api.sleeper.app/v1/league/${leagueId}`);
    const leagueData = await leagueRes.json();

    const usersRes = await fetch(`https://api.sleeper.app/v1/league/${leagueId}/users`);
    const users = await usersRes.json();

    const rostersRes = await fetch(`https://api.sleeper.app/v1/league/${leagueId}/rosters`);
    const rosters = await rostersRes.json();

    const playerMap = await fetchInternalPlayers();

    // Write league
    const leagueRef = doc(db, 'leagues', leagueId);
    await setDoc(leagueRef, {
      name: leagueData.name,
      scoringFormat: leagueData.scoring_settings,
      createdBy: user.uid,
      source: "Sleeper",
      createdAt: new Date().toISOString()
    });

    // Write teams with matched rosters
    for (const roster of rosters) {
      const userData = users.find(u => u.user_id === roster.owner_id);
      if (!userData) continue;

      const matchedRoster = (roster.players || []).map(pid => playerMap[pid]).filter(Boolean);

      await addDoc(collection(db, 'teams'), {
        teamName: userData.display_name || "Unnamed Team",
        userId: userData.user_id,
        leagueId: leagueId,
        importedRoster: roster.players || [],
        matchedRoster,
        joinedAt: new Date().toISOString()
      });
    }

    output.innerHTML = `<div class='alert alert-success'>🎉 League "${leagueData.name}" imported with matched rosters.</div>`;
  } catch (err) {
    console.error(err);
    output.innerHTML = "<div class='alert alert-danger'>❌ Error during import. Check console for details.</div>";
  }
});
