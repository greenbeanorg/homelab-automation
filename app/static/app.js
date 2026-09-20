const taskList = document.getElementById("task-list");
const emptyState = document.getElementById("empty-state");
const addForm = document.getElementById("add-form");
const newTitleInput = document.getElementById("new-title");

async function loadTasks() {
  const res = await fetch("/tasks");
  const tasks = await res.json();
  renderTasks(tasks);
}

function renderTasks(tasks) {
  taskList.innerHTML = "";
  emptyState.hidden = tasks.length > 0;

  for (const task of tasks) {
    const li = document.createElement("li");
    li.className = "task" + (task.done ? " done" : "");

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = task.done;
    checkbox.addEventListener("change", () => toggleDone(task.id, checkbox.checked));

    const title = document.createElement("span");
    title.className = "title";
    title.textContent = task.title;

    const deleteBtn = document.createElement("button");
    deleteBtn.className = "delete";
    deleteBtn.textContent = "Delete";
    deleteBtn.addEventListener("click", () => deleteTask(task.id));

    li.appendChild(checkbox);
    li.appendChild(title);
    li.appendChild(deleteBtn);
    taskList.appendChild(li);
  }
}

async function toggleDone(id, done) {
  await fetch(`/tasks/${id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ done }),
  });
  loadTasks();
}

async function deleteTask(id) {
  await fetch(`/tasks/${id}`, { method: "DELETE" });
  loadTasks();
}

addForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const title = newTitleInput.value.trim();
  if (!title) return;

  await fetch("/tasks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title }),
  });

  newTitleInput.value = "";
  loadTasks();
});

loadTasks();
