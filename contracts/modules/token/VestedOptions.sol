pragma solidity >=0.4.24 <0.5.0;

import "../ModuleBase.sol";
import "../../open-zeppelin/SafeMath.sol";

contract VestedOptions is STModuleBase {

	using SafeMath for uint256;
	using SafeMath32 for uint32;

	string public constant name = "Options";

	uint256 public totalOptions;
	uint256 public ethPeg;
	uint32 public expiryDate;
	uint32 public terminationGracePeriod;
	address public receiver;

	mapping (bytes32 => Option[]) optionData;
	mapping (bytes32 => uint256) public options;

	struct Option {
		uint96 amount;
		uint96 exercisePrice;
		uint32 creationDate;
		uint32 vestDate;
	}

	/**
		@notice supply permissions and hook points when attaching module
		@dev
			permissions: 0x40c10f19 - mint
			hooks: 0xb1a1a455 - modifyAuthorizedSupply
				   0x741b5078 - totalSupplyChanged
			hookBools - all true
	 */
	function getPermissions()
		external
		pure
		returns
	(
		bytes4[] permissions,
		bytes4[] hooks,
		uint256 hookBools
	)
	{
		permissions = new bytes4[](1);
		permissions[0] = 0x40c10f19;
		hooks = new bytes4[](2);
		hooks[0] = 0xb1a1a455;
		hooks[1] = 0x741b5078;
		return (permissions, hooks, uint256(-1));
	}

	/**
		@notice constructor
		@param _token token address
		@param _issuer issuer address
		@param _expiry time for options to expire, in seconds
		@param _gracePeriod amount of time that already vested options are
							claimable if terminated
		@param _receiver address to send ETH to when options are exercised
	 */
	constructor(
		address _token,
		address _issuer,
		uint32 _expiry,
		uint32 _gracePeriod,
		address _receiver
	)
		public
		STModuleBase(_token, _issuer)
	{
		expiryDate = _expiry;
		terminationGracePeriod = _gracePeriod;
		receiver = _receiver;
	}

	/**
		@notice Modify eth peg
		@dev
			The peg is multiplied by the exercise price to determine the amount
			in wei that must be paid when exercising an option.
		@param _peg new peg value
		@return bool
	 */
	function modifyPeg(uint256 _peg) external returns (bool) {
		if (!_onlyAuthority()) return false;
		ethPeg = _peg;
		return true;
	}

	/**
		@notice issue new options
		@param _id investor ID
		@param _amount array, quantities of options to issue
		@param _exercisePrice array, exercise price per group of options
		@param _vestDate array, relative time for options to vest (seconds from now)
		@return bool success
	 */
	function issueOptions(
		bytes32 _id,
		uint96[] _amount,
		uint96[] _exercisePrice,
		uint32[] _vestDate
	)
		external
		returns (bool)
	{
		if (!_onlyAuthority()) return false;
		require(_amount.length == _exercisePrice.length);
		require(_amount.length == _vestDate.length);
		uint256 _total;
		for (uint256 i; i < _amount.length; i++) {
			optionData[_id].push(Option(
				_amount[i],
				_exercisePrice[i],
				uint32(now),
				uint32(now).add(_vestDate[i])
			));
			_total = _total.add(_amount[i]);
		}
		options[_id] = options[_id].add(_total);
		totalOptions = totalOptions.add(_total);
		return true;
	}

	/**
		@notice modify vesting date for one or more groups of options
		@dev time to vest can only be shortened, not extended
		@param _id investor ID
		@param _idx array, option indexes
		@param _vestDate new absolute time for options to vest
		@return bool success
	 */
	function accellerateVestingDate(
		bytes32 _id,
		uint256[] _idx,
		uint32 _vestDate
	)
		external
		returns (bool)
	{
		if (!_onlyAuthority()) return false;
		for (uint256 i; i < _idx.length; i++) {
			require(
				optionData[_id][_idx[i]].vestDate >= _vestDate,
				"Cannot extend vesting date"
			);
			optionData[_id][_idx[i]].vestDate = _vestDate;
		}
		return true;
	}

	/**
		@notice exercise vested options
		@dev payable method, payment must exactly equal:
			exercise price * number of options * eth peg
		@param _idx array, option indexes
		@return bool success
	 */
	function exerciseOptions(uint256[] _idx) external payable returns (bool) {
		bytes32 _id = issuer.getID(msg.sender);
		uint256 _amount;
		uint256 _price;
		for (uint256 i; i < _idx.length; i++) {
			Option storage o = optionData[_id][_idx[i]];
			require(o.vestDate <= now, "Options have not vested");
			require(o.creationDate.add(expiryDate) > now, "Options have expired");
			_amount = _amount.add(o.amount);
			_price = _price.add(uint256(o.exercisePrice).mul(o.amount));
			delete optionData[_id][_idx[i]];
		}
		require(msg.value == _price.mul(ethPeg), "Incorrect payment amount");
		receiver.transfer(address(this).balance);
		totalOptions = totalOptions.sub(_amount);
		options[_id] = options[_id].sub(_amount);
		require(token.mint(msg.sender, _amount));
		return true;
	}

	/**
		@notice cancel expired options
		@dev
			This method does not need to be called to block the claim of expired
			options. It is used to reduce totalOptions, freeing up the authorized
			supply so that other options or tokens may be issued.
		@param _id Investor ID
		@return bool success
	 */
	function cancelExpiredOptions(bytes32 _id) external returns (bool) {
		Option[] storage o = optionData[_id];
		uint256 _amount;
		for (uint256 i; i < o.length; i++) {
			if (o[i].creationDate.add(expiryDate) > now) continue;
			_amount = _amount.add(o[i].amount);
			delete o[i];
		}
		totalOptions = totalOptions.sub(_amount);
		options[_id] = options[_id].sub(_amount);
		return true;
	}

	/**
		@notice Terminate options
		@dev
			Terminates all options associated with an investor ID. Any
			groups that had already vested will still be available for
			terminationGracePeriod seconds.
		@param _id Investor ID
		@return bool success
	 */
	function terminateOptions(bytes32 _id) external returns (bool) {
		if (!_onlyAuthority()) return false;
		Option[] storage o = optionData[_id];
		uint256 _amount;
		for (uint256 i; i < o.length; i++) {
			if (o[i].vestDate > now) {
				_amount = _amount.add(o[i].amount);
				delete o[i];
			} else {
				o[i].creationDate = uint32(now).sub(expiryDate).add(terminationGracePeriod);
			}
		}
		totalOptions = totalOptions.sub(_amount);
		options[_id] = options[_id].sub(_amount);
		return true;
	}

	/**
		@notice Total supply hook point method
		@dev Prevents totalSupply + totalOptions from exceeding authorizedSupply
	 */
	function totalSupplyChanged(
		address,
		bytes32,
		uint8,
		uint16,
		uint256 _old,
		uint256 _new
	)
		external
		view
		returns (bool)
	{
		if (_old > _new) {
			require(token.authorizedSupply().sub(token.totalSupply()) >= totalOptions);
		}
		return true;
		
	}

	/**
		@notice Authorized supply hook point method
		@dev Prevents totalSupply + totalOptions from exceeding authorizedSupply
	 */
	function modifyAuthorizedSupply(
		address,
		uint256 _oldSupply,
		uint256 _newSupply
	)
		external
		view
		returns (bool)
	{
		if (_oldSupply > _newSupply) {
			require(_newSupply.sub(token.totalSupply()) >= totalOptions);
		}
		return true;
	}

}
