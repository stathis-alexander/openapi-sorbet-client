    sig do
      params(
        pet_id: String,
        filter: T.nilable(String),
        authorization: T.nilable(String)
      ).returns(Models::Pet)
    end
    def get_pet(pet_id:, filter: nil, authorization: nil)
