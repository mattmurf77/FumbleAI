
import { rerankTier } from './ranking-enhanced.js';

// Render tiers with player cards and confidence bars
export function renderTiersWithUI(tiers, containerId) {
  const container = document.getElementById(containerId);
  container.innerHTML = '';

  tiers.forEach((tier, idx) => {
    const tierDiv = document.createElement('div');
    tierDiv.className = 'mb-4';
    tierDiv.innerHTML = `<h5 class='mb-3'>Tier ${idx + 1}</h5>`;

    const list = document.createElement('ul');
    list.className = 'list-group tier-list';
    list.dataset.tierIndex = idx;

    tier.forEach(player => {
      const item = document.createElement('li');
      item.className = 'list-group-item d-flex justify-content-between align-items-center';
      item.draggable = true;
      item.dataset.playerId = player.playerId;

      item.innerHTML = `
        <div>
          <strong>${player.name}</strong> (${player.position})
          <div style="font-size: 12px; color: #555;">
            Elo: ${Math.round(player.elo)} | Confidence: ${Math.round(player.confidence)}
          </div>
        </div>
        <div class="confidence-bar" style="background: #f5bf00; height: 8px; width: ${Math.min(player.confidence, 100)}%; border-radius: 4px;"></div>
      `;

      addDragEvents(item);
      list.appendChild(item);
    });

    const rerankBtn = document.createElement('button');
    rerankBtn.className = 'btn btn-sm btn-outline-primary mt-2';
    rerankBtn.innerText = 'Re-rank this tier';
    rerankBtn.onclick = () => saveRerank(list, tier);

    tierDiv.appendChild(list);
    tierDiv.appendChild(rerankBtn);
    container.appendChild(tierDiv);
  });
}

// Handle drag-and-drop logic
function addDragEvents(item) {
  item.addEventListener('dragstart', e => {
    e.dataTransfer.setData('text/plain', e.target.dataset.playerId);
  });

  item.addEventListener('dragover', e => e.preventDefault());

  item.addEventListener('drop', e => {
    e.preventDefault();
    const draggedId = e.dataTransfer.getData('text');
    const targetId = e.target.closest('li').dataset.playerId;
    const list = e.target.closest('ul');
    const draggedItem = [...list.children].find(li => li.dataset.playerId === draggedId);
    const targetItem = [...list.children].find(li => li.dataset.playerId === targetId);

    if (draggedItem && targetItem) {
      if (draggedItem !== targetItem) {
        list.insertBefore(draggedItem, draggedItem.compareDocumentPosition(targetItem) & Node.DOCUMENT_POSITION_FOLLOWING ? targetItem : targetItem.nextSibling);
      }
    }
  });
}

// Save reordered tier back to Firestore using rerankTier
async function saveRerank(list, originalTier) {
  const orderedIds = [...list.children].map(li => li.dataset.playerId);
  const scoringFormat = 'PPR'; // or dynamic value
  await rerankTier(originalTier, orderedIds, scoringFormat);
  alert('Tier re-ranked!');
}
