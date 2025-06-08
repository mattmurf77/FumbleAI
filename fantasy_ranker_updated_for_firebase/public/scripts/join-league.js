import { db, auth } from './firebase-auth.js';
import { collection, doc, getDoc, addDoc } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

// Get leagueId from query param
const params = new URLSearchParams(window.location.search);
const leagueId = params.get('leagueId');

if (!leagueId) {
  document.body.innerHTML = "<div class='p-4'>Invalid invite link.</div>";
} else {
  auth.onAuthStateChanged(async (user) => {
    if (user) {
      const leagueRef = doc(db, 'leagues', leagueId);
      const leagueSnap = await getDoc(leagueRef);
      if (leagueSnap.exists()) {
        const leagueData = leagueSnap.data();
        const userTeam = {
          userId: user.uid,
          leagueId: leagueId,
          teamName: `${user.displayName || "Unnamed"}'s Team`,
          joinedAt: new Date().toISOString()
        };
        await addDoc(collection(db, 'teams'), userTeam);
        document.getElementById('league-name').textContent = leagueData.name;
        document.getElementById('status').textContent = "✅ You have joined the league!";
      } else {
        document.body.innerHTML = "<div class='p-4'>League not found.</div>";
      }
    }
  });
}
