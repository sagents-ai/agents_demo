defmodule AgentsDemoWeb.UserLive.Registration do
  use AgentsDemoWeb, :live_view

  alias AgentsDemo.Accounts
  alias AgentsDemo.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen bg-[var(--color-background)] overflow-hidden">
      <div class="flex flex-1 items-center justify-center p-8">
        <div class="max-w-md w-full">
          <div class="mb-8 flex justify-center">
            <.link navigate={~p"/"} class="no-underline">
              <div class="w-16 h-16 rounded-full bg-[var(--color-primary)] flex items-center justify-center">
                <.icon name="hero-chat-bubble-left-right" class="w-10 h-10 text-white" />
              </div>
            </.link>
          </div>

          <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-xl p-8 shadow-lg">
            <div class="text-center mb-6">
              <h1 class="text-3xl font-bold text-[var(--color-text-primary)] mb-2">
                Register for an Account
              </h1>
              <p class="text-[var(--color-text-secondary)]">
                Already registered?
                <.link
                  navigate={~p"/users/log-in"}
                  class="font-semibold text-[var(--color-primary)] hover:underline no-underline"
                >
                  Log in
                </.link>
                to your account now.
              </p>
            </div>

            <.form
              for={@form}
              id="registration_form"
              phx-submit="save"
              phx-change="validate"
              class="space-y-4"
            >
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                required
                phx-mounted={JS.focus()}
              />

              <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
                Create an account
              </.button>
            </.form>
          </div>

          <div class="mt-6 text-center">
            <.link
              navigate={~p"/"}
              class="text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-primary)] no-underline"
            >
              ← Back to home
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: AgentsDemoWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
