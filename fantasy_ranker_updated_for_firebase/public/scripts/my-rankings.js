import { db, auth } from './firebase-auth.js';
import { collection, query, where, getDocs } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

async function loadRankings() {
  const user = auth.currentUser;
  if (!user) return;

  const q = query(collection(db, 'user_swipes'), where('user_id', '==', user.uid));
  const snapshot = await getDocs(q);
  const rankings = [];

  snapshot.forEach(doc => {
    const data = doc.data();
    rankings.push(data);
  });

  rankings.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

  const list = document.getElementById('ranking-list');
  rankings.forEach((rank, index) => {
    const li = document.createElement('li');
    li.className = 'list-group-item';
    li.textContent = `${index + 1}. ${rank.player_id} (${rank.direction})`;
    list.appendChild(li);
  });
}

auth.onAuthStateChanged(user => {
  if (user) loadRankings();
});
