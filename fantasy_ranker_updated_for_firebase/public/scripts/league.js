import { db, auth } from './firebase-auth.js';
import { collection, addDoc } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

document.getElementById('league-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const leagueName = document.getElementById('leagueName').value;
  const scoringFormat = document.getElementById('scoringFormat').value;
  const user = auth.currentUser;

  if (!user) return alert('Please sign in first');

  try {
    await addDoc(collection(db, 'leagues'), {
      name: leagueName,
      scoringFormat,
      createdBy: user.uid,
      createdAt: new Date().toISOString()
    });
    alert('League created!');
    e.target.reset();
  } catch (err) {
    console.error(err);
    alert('Error creating league');
  }
});
