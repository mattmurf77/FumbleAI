import { db, auth } from './firebase-auth.js';
import { doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

const params = new URLSearchParams(window.location.search);
const teamId = params.get('teamId');

async function loadRoster() {
  if (!teamId) return;

  const teamRef = doc(db, 'teams', teamId);
  const teamSnap = await getDoc(teamRef);
  const list = document.getElementById('roster-list');

  if (!teamSnap.exists()) {
    list.innerHTML = '<li class="list-group-item">Roster not found.</li>';
    return;
  }

  const team = teamSnap.data();
  // For this mockup, we just list the team name. You can replace this with actual roster logic
  const li = document.createElement('li');
  li.className = 'list-group-item';
  li.textContent = `${team.teamName} (Owner: ${team.userId})`;
  list.appendChild(li);
}

auth.onAuthStateChanged(user => {
  if (user) loadRoster();
});
