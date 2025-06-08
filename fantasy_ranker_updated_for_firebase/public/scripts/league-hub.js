import { db, auth } from './firebase-auth.js';
import { doc, getDoc, query, collection, where, getDocs } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

const params = new URLSearchParams(window.location.search);
const leagueId = params.get('leagueId');

async function loadLeagueHub() {
  if (!leagueId) return;

  const leagueRef = doc(db, 'leagues', leagueId);
  const leagueSnap = await getDoc(leagueRef);
  if (!leagueSnap.exists()) {
    document.body.innerHTML = '<div class="p-4">League not found</div>';
    return;
  }

  document.getElementById('league-name').textContent = leagueSnap.data().name;

  const q = query(collection(db, 'teams'), where('leagueId', '==', leagueId));
  const snapshot = await getDocs(q);
  const list = document.getElementById('team-list');

  snapshot.forEach(doc => {
    const team = doc.data();
    const li = document.createElement('li');
    li.className = 'list-group-item d-flex justify-content-between align-items-center';
    li.textContent = team.teamName;

    const btn = document.createElement('button');
    btn.className = 'btn btn-sm btn-outline-primary';
    btn.textContent = 'View Roster';
    btn.onclick = () => {
      window.location.href = `view-roster.html?teamId=${doc.id}`;
    };

    li.appendChild(btn);
    list.appendChild(li);
  });
}

auth.onAuthStateChanged(user => {
  if (user) loadLeagueHub();
});
