import { db, auth } from './firebase-auth.js';
import { collection, addDoc, getDocs, deleteDoc, doc, query, where } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

const teamForm = document.getElementById('team-form');
const teamList = document.getElementById('team-list');

teamForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const teamName = document.getElementById('teamName').value;
  const user = auth.currentUser;
  if (!user) return;

  await addDoc(collection(db, 'teams'), {
    name: teamName,
    userId: user.uid,
    createdAt: new Date().toISOString()
  });

  teamForm.reset();
  loadTeams();
});

async function loadTeams() {
  teamList.innerHTML = '';
  const user = auth.currentUser;
  if (!user) return;

  const q = query(collection(db, 'teams'), where('userId', '==', user.uid));
  const snapshot = await getDocs(q);
  snapshot.forEach(teamDoc => {
    const team = teamDoc.data();
    const li = document.createElement('li');
    li.className = 'list-group-item d-flex justify-content-between align-items-center';
    li.textContent = team.name;

    const btn = document.createElement('button');
    btn.className = 'btn btn-sm btn-danger';
    btn.textContent = 'Delete';
    btn.onclick = async () => {
      await deleteDoc(doc(db, 'teams', teamDoc.id));
      loadTeams();
    };

    li.appendChild(btn);
    teamList.appendChild(li);
  });
}

auth.onAuthStateChanged(user => {
  if (user) loadTeams();
});
